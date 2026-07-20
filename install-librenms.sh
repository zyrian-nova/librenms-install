#!/bin/bash

# Salida al encontrar errores
set -e
echo
echo "#################################"
echo "Iniciando instalación de LibreNMS..."
echo "#################################"
echo

read -sp "Ingresa la contraseña para el usuario librenms: " DATABASEPASSWORD
echo

read -p "Ingresa el nombre del servidor web: " WEBSERVERHOSTNAME

echo
echo "##############################"
echo "Instalando paquetes requeridos"
echo "##############################"
echo

dnf makecache --refresh
dnf install -y epel-release
dnf install -y https://rpms.remirepo.net/enterprise/remi-release-8.rpm
dnf module reset php -y
dnf module enable php:remi-8.2 -y
dnf makecache --refresh
dnf install -y acl curl fping git graphviz ImageMagick mariadb mariadb-server mtr nmap nginx php-cli php-curl php-fpm php-process php-gd php-gmp php-json php-mbstring php-pdo php-mysqlnd php-xml php-zip rrdtool net-snmp net-snmp-utils unzip python3-PyMySQL python3-dotenv python3-redis python3-setuptools python3-psutil python3-systemd python3-pip whois traceroute iputils tcpdump vim cronie gcc python3-devel libffi-devel openssl-devel make

echo
echo "##############################"
echo "Creando usuario librenms"
echo "##############################"
echo

if ! id "librenms" &>/dev/null; then
    useradd librenms -d /opt/librenms -M -r -s "$(which bash)"
    echo "Usuario librenms creado exitosamente"
else
    echo "El usuario librenms ya existe, omitiendo creación"
fi

echo "##############################"
echo "Clonando repositorio LibreNMS"
echo "##############################"
echo

if [ -d "/opt/librenms" ]; then
    echo "El directorio /opt/librenms ya existe"
    echo "Actualizando repositorio existente..."
    cd /opt/librenms
    git pull origin master
else
    echo "Clonando repositorio LibreNMS..."
    cd /opt
    git clone https://github.com/librenms/librenms.git
fi

echo

echo
echo "############################################"
echo "Aplicando permisos a directorios de LibreNMS"
echo "############################################"
echo

chown -R librenms:librenms /opt/librenms
chmod 771 /opt/librenms
setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/

echo "#####################################"
echo "Instalando dependencias de Composer"
echo "#####################################"
echo

su - librenms -c "/opt/librenms/scripts/composer_wrapper.php install --no-dev"

echo
echo "##################################"
echo "Configurando zona horaria de PHP"
echo "##################################"

sed -i 's/;date.timezone =/date.timezone = America\/Mazatlan/' /etc/php.ini

echo
echo "#############################################"
echo "Configurando zona horaria del sistema"
echo "#############################################"
echo
timedatectl set-timezone America/Mazatlan

echo "############################"
echo "Configurando MariaDB"
echo "############################"
echo

grep -q "innodb_file_per_table" /etc/my.cnf.d/mariadb-server.cnf || \
sed -i '/\[mysqld\]/a innodb_file_per_table=1' /etc/my.cnf.d/mariadb-server.cnf

grep -q "lower_case_table_names" /etc/my.cnf.d/mariadb-server.cnf || \
sed -i '/\[mysqld\]/a lower_case_table_names=0' /etc/my.cnf.d/mariadb-server.cnf

echo "###############################"
echo "Activando y reiniciando MariaDB"
echo "###############################"
echo

systemctl enable mariadb
systemctl restart mariadb

echo
echo "############################################"
echo "Creando base de datos y usuario de LibreNMS"
echo "############################################"


# Verificando existencia de la base de datos
if mysql -u root -e "USE librenms" 2>/dev/null; then
    echo "La base de datos librenms ya existe, omitiendo creación"
else
    echo "Creando base de datos librenms..."
    mysql -u root <<EOF
CREATE DATABASE librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
EOF
fi

# Verificando existencia de usuario
if mysql -u root -e "SELECT User FROM mysql.user WHERE User='librenms' AND Host='localhost'" | grep -q librenms; then
    echo "El usuario librenms ya existe, actualizando contraseña..."
    mysql -u root <<EOF
ALTER USER 'librenms'@'localhost' IDENTIFIED BY '$DATABASEPASSWORD';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';
FLUSH PRIVILEGES;
EOF
else
    echo "Creando usuario librenms..."
    mysql -u root <<EOF
CREATE USER 'librenms'@'localhost' IDENTIFIED BY '$DATABASEPASSWORD';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';
FLUSH PRIVILEGES;
EOF
fi

echo

echo
echo "########################################"
echo "Configurando SELinux en modo permissivo"
echo "########################################"
echo

# Configurando SELinux en modo permissivo
setenforce 0 || true

# Persistir el cambio en reinicios
if [ -f /etc/selinux/config ]; then
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
    sed -i 's/^SELINUX=disabled/SELINUX=permissive/' /etc/selinux/config
fi

echo

echo
echo "#########################################"
echo "Configurando PHP-FPM pool para LibreNMS"
echo "#########################################"

# Crear pool LibreNMS desde www.conf si no existe
if [ ! -f /etc/php-fpm.d/librenms.conf ]; then
    if [ -f /etc/php-fpm.d/www.conf ]; then
        cp /etc/php-fpm.d/www.conf /etc/php-fpm.d/librenms.conf

        # Deshabilitar pool por defecto para evitar conflictos
        mv /etc/php-fpm.d/www.conf /etc/php-fpm.d/www.conf.bak
    else
        echo "No se encontró el pool por defecto"
        exit 1
    fi
else
    echo "el pool LibreNMS ya existe, se omite la creación"
fi

# Configurar pool LibreNMS
sed -i 's/^\[.*\]/[librenms]/' /etc/php-fpm.d/librenms.conf
sed -i 's/^user = .*/user = librenms/' /etc/php-fpm.d/librenms.conf
sed -i 's/^group = .*/group = librenms/' /etc/php-fpm.d/librenms.conf
sed -i 's|^listen = .*|listen = /run/php-fpm-librenms.sock|' /etc/php-fpm.d/librenms.conf

# Agregar permisos de socket
grep -q "listen.owner" /etc/php-fpm.d/librenms.conf || cat <<EOF >> /etc/php-fpm.d/librenms.conf
listen.owner = nginx
listen.group = nginx
listen.mode = 0660
EOF

echo

echo
echo "##################################"
echo "Configurando Nginx para LibreNMS"
echo "##################################"

cat << EOF > /etc/nginx/conf.d/librenms.conf
server {
 listen      80;
 server_name $WEBSERVERHOSTNAME;
 root        /opt/librenms/html;
 index       index.php;

 charset utf-8;
 gzip on;
 gzip_types text/css application/javascript text/javascript application/x-javascript image/svg+xml text/plain text/xsd text/xsl text/xml image/x-icon;
 location / {
  try_files \$uri \$uri/ /index.php?\$query_string;
 }
 location ~ [^/]\.php(/|$) {
  fastcgi_pass unix:/run/php-fpm-librenms.sock;
  fastcgi_split_path_info ^(.+\.php)(/.+)$;
  include fastcgi.conf;
 }
 location ~ /\.(?!well-known).* {
  deny all;
 }
}
EOF



echo
echo "##############################################"
echo "Removiendo configuración por defecto de Nginx"
echo "##############################################"

rm -f /etc/nginx/conf.d/default.conf

echo
echo "Reiniciando Nginx y PHP-FPM..."
echo

systemctl enable nginx
systemctl enable php-fpm
systemctl enable snmpd

php-fpm -t || { echo "Error en la configuración de PHP-FPM"; exit 1; }

systemctl restart nginx
systemctl restart php-fpm

echo "##########################"
echo "Configurando comando lnms"
echo "##########################"
echo

ln -sf /opt/librenms/lnms /usr/bin/lnms
cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/

echo "################"
echo "Configurando SNMP"
echo "################"

cp /opt/librenms/snmpd.conf.example /etc/snmp/snmpd.conf
sed -i 's/RANDOMSTRINGGOESHERE/public/' /etc/snmp/snmpd.conf
curl -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
chmod +x /usr/bin/distro
systemctl enable snmpd
systemctl restart snmpd

echo

cp /opt/librenms/dist/librenms.cron /etc/cron.d/librenms

echo
echo "####################################"
echo "Activando temporizador de LibreNMS"
echo "####################################"
echo

cp /opt/librenms/dist/librenms-scheduler.service /opt/librenms/dist/librenms-scheduler.timer /etc/systemd/system/
systemctl enable librenms-scheduler.timer
systemctl start librenms-scheduler.timer

echo
echo "#####################################"
echo "Configurando logrotate para LibreNMS"
echo "#####################################"

cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms

echo

echo "####################################"
echo "Instalando y configurando rsyslog"
echo "####################################"
echo

# Asegurando que rsyslog esté instalado
if ! command -v rsyslogd >/dev/null 2>&1; then
    echo "Installing rsyslog..."
    dnf install -y rsyslog
fi

# Asegurando que el directorio de configuración de rsyslog exista
mkdir -p /etc/rsyslog.d

cat << 'EOF' > /etc/rsyslog.d/librenms.conf
$ModLoad imudp
$UDPServerRun 514

$ModLoad imtcp
$InputTCPServerRun 514

:syslogtag, contains, "librenms" |/opt/librenms/syslog.php
& stop
EOF

systemctl enable --now rsyslog
systemctl restart rsyslog

echo

chown librenms:librenms /opt/librenms/syslog.php
chmod +x /opt/librenms/syslog.php

echo "Reiniciando rsyslog..."
systemctl restart rsyslog

echo
echo "#######################"
echo "Editando el archivo .env"
echo "#######################"

sed -i "s/#DB_HOST=/DB_HOST=localhost/" /opt/librenms/.env
sed -i "s/#DB_DATABASE=/DB_DATABASE=librenms/" /opt/librenms/.env
sed -i "s/#DB_USERNAME=/DB_USERNAME=librenms/" /opt/librenms/.env
sed -i "s/#DB_PASSWORD=/DB_PASSWORD=$DATABASEPASSWORD/" /opt/librenms/.env


echo
echo "#####################"
echo "Editando permisos de log"
echo "#####################"
echo

while true; do
  if [ -f /opt/librenms/logs/librenms.log ]; then
    chown librenms:librenms /opt/librenms/logs/librenms.log
    break
  else
    echo "Esperando que el archivo de log aparezca..."
    sleep 1
  fi
done

echo

echo
echo "Instalación y configuración de LibreNMS casi completada"
echo "...casi"
echo
echo "#####################################"
echo "No olvides volver y hacer esto"
echo "#####################################"
echo
echo "Ve a la página web y haz la configuración..."
echo "...después vuelve y haz esto:"
echo
echo 'su librenms -c "lnms config:set enable_syslog true"'
echo
echo "El sistema estará listo."
echo
echo "Espera a que el sistema se inicie y luego haz la validación:"
echo
echo "su librenms -c /opt/librenms/validate.php"
echo
echo "Si hay un problema de python (con PIP) ejecuta el siguiente comando"
echo
echo "pip3 install --user -r /opt/librenms/requirements.txt"
echo

exit 0
