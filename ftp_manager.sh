#!/bin/bash
MASTER_DIR="/var/ftp_master"

instalar_vsftpd() {
    echo "Instalando vsftpd..."
    if command -v dnf &> /dev/null; then
        dnf install -y vsftpd
    elif command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y vsftpd
    fi
    cat <<EOF > /etc/vsftpd.conf
listen=NO
listen_ipv6=YES
anonymous_enable=YES
anon_root=$MASTER_DIR/general
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
chroot_local_user=YES
allow_writeable_chroot=YES
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
rsa_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem
rsa_private_key_file=/etc/ssl/private/ssl-cert-snakeoil.key
ssl_enable=NO
EOF

    systemctl enable vsftpd --now
    systemctl restart vsftpd
    
    if command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-service=ftp
        firewall-cmd --reload
    fi
}

crear_estructura_base() {
    echo "Creando estructura de carpetas maestra..."
    mkdir -p $MASTER_DIR/{general,reprobados,recursadores}
    chmod 777 $MASTER_DIR/general
    
    groupadd -f reprobados
    groupadd -f recursadores
    
    chown root:reprobados $MASTER_DIR/reprobados
    chmod 770 $MASTER_DIR/reprobados
    
    chown root:recursadores $MASTER_DIR/recursadores
    chmod 770 $MASTER_DIR/recursadores
}

crear_usuarios() {
    read -p "¿Cuántos usuarios deseas crear?: " n
    for ((i=1; i<=n; i++)); do
        read -p "Nombre del usuario $i: " user
        read -s -p "Contraseña para $user: " pass; echo
        read -p "Grupo (reprobados/recursadores): " grupo
        
        if [[ "$grupo" != "reprobados" && "$grupo" != "recursadores" ]]; then
            echo "Grupo inválido. Omitiendo usuario."
            continue
        fi

        # Crear usuario
        useradd -m -d /home/$user -s /sbin/nologin -G $grupo $user
        echo "$user:$pass" | chpasswd

        # Estructura interna (Lo que ve el usuario por FTP)
        USER_FTP_DIR="/home/$user/ftp"
        mkdir -p $USER_FTP_DIR/{general,$grupo,$user}
        chown root:root $USER_FTP_DIR # Necesario para chroot de vsftpd
        chmod 755 $USER_FTP_DIR
        
        chown $user:$grupo $USER_FTP_DIR/$user
        chmod 700 $USER_FTP_DIR/$user

        # Montajes virtuales para reflejar las carpetas maestras dentro del home del usuario
        mount --bind $MASTER_DIR/general $USER_FTP_DIR/general
        mount --bind $MASTER_DIR/$grupo $USER_FTP_DIR/$grupo
        
        # Persistencia en fstab
        echo "$MASTER_DIR/general $USER_FTP_DIR/general none bind 0 0" >> /etc/fstab
        echo "$MASTER_DIR/$grupo $USER_FTP_DIR/$grupo none bind 0 0" >> /etc/fstab

        # Decirle a vsftpd dónde iniciar sesión
        usermod -d $USER_FTP_DIR $user
        echo "Usuario $user creado y estructurado con éxito."
    done
}

cambiar_grupo() {
    read -p "Usuario a modificar: " user
    read -p "Nuevo grupo (reprobados/recursadores): " nuevo_grupo
    
    viejo_grupo=$(id -nG $user | grep -oE "reprobados|recursadores")
    
    if [ "$nuevo_grupo" == "$viejo_grupo" ]; then
        echo "El usuario ya está en ese grupo."
        return
    fi
    
    # Cambiar grupo
    usermod -g $nuevo_grupo -G "" $user
    
    # Ajustar carpetas y montajes
    USER_FTP_DIR="/home/$user/ftp"
    umount $USER_FTP_DIR/$viejo_grupo
    sed -i "\|\$USER_FTP_DIR/$viejo_grupo|d" /etc/fstab
    
    rmdir $USER_FTP_DIR/$viejo_grupo
    mkdir -p $USER_FTP_DIR/$nuevo_grupo
    
    mount --bind $MASTER_DIR/$nuevo_grupo $USER_FTP_DIR/$nuevo_grupo
    echo "$MASTER_DIR/$nuevo_grupo $USER_FTP_DIR/$nuevo_grupo none bind 0 0" >> /etc/fstab
    
    echo "Grupo actualizado con éxito."
}

# Menú
echo "1. Instalar vsftpd y crear estructura base"
echo "2. Crear usuarios y asignar grupos"
echo "3. Cambiar usuario de grupo"
read -p "Selecciona una opción: " opc

case $opc in
    1) instalar_vsftpd; crear_estructura_base ;;
    2) crear_usuarios ;;
    3) cambiar_grupo ;;
    *) echo "Opción inválida" ;;
esac
