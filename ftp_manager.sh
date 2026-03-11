#!/bin/bash

C_ERROR='\033[0;31m'
C_EXITO='\033[0;32m'
C_INFO='\033[0;36m'
C_TITULO='\033[1;33m'
C_RESET='\033[0m'

preparar_entorno_ftp() {
    echo -e "${C_INFO}[*] Configurando servidor VSFTPD...${C_RESET}"
    sudo dnf install -y vsftpd util-linux acl e2fsprogs policycoreutils-python-utils &>/dev/null

    cat <<EOF | sudo tee /etc/vsftpd/vsftpd.conf > /dev/null
anonymous_enable=YES
local_enable=YES
write_enable=YES
local_umask=002
chroot_local_user=YES
allow_writeable_chroot=YES
check_shell=NO
anon_root=/srv/ftp/anonymous
no_anon_password=YES
anon_world_readable_only=YES
anon_mkdir_write_enable=NO
anon_upload_enable=NO
anon_other_write_enable=NO
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40010
listen=NO
listen_ipv6=YES
pam_service_name=vsftpd
EOF

    sudo mkdir -p /srv/ftp/{grupos/reprobados,grupos/recursadores,publico,anonymous/general}

    sudo groupadd -f reprobados
    sudo groupadd -f recursadores
    sudo groupadd -f grupo-ftp

    sudo chown ftp:ftp /srv/ftp/anonymous
    sudo chmod 555 /srv/ftp/anonymous

    sudo chown root:grupo-ftp /srv/ftp/publico
    sudo chmod 1777 /srv/ftp/publico 
    sudo setfacl -R -m g:grupo-ftp:rwx /srv/ftp/publico 2>/dev/null
    sudo setfacl -R -d -m g:grupo-ftp:rwx /srv/ftp/publico 2>/dev/null

    sudo chown root:reprobados /srv/ftp/grupos/reprobados
    sudo chmod 1777 /srv/ftp/grupos/reprobados
    sudo setfacl -R -m g:reprobados:rwx /srv/ftp/grupos/reprobados 2>/dev/null
    sudo setfacl -R -d -m g:reprobados:rwx /srv/ftp/grupos/reprobados 2>/dev/null

    sudo chown root:recursadores /srv/ftp/grupos/recursadores
    sudo chmod 1777 /srv/ftp/grupos/recursadores
    sudo setfacl -R -m g:recursadores:rwx /srv/ftp/grupos/recursadores 2>/dev/null
    sudo setfacl -R -d -m g:recursadores:rwx /srv/ftp/grupos/recursadores 2>/dev/null

    if ! grep -q "^/srv/ftp/publico /srv/ftp/anonymous/general " /etc/fstab; then
        echo "/srv/ftp/publico /srv/ftp/anonymous/general none bind,ro 0 0" | sudo tee -a /etc/fstab > /dev/null
    fi

    sudo mountpoint -q /srv/ftp/anonymous/general || sudo mount /srv/ftp/anonymous/general 2>/dev/null
    sudo mount -a

    sudo firewall-cmd --permanent --add-service=ftp &>/dev/null
    sudo firewall-cmd --permanent --add-port=40000-40010/tcp &>/dev/null
    sudo firewall-cmd --reload &>/dev/null

    sudo setsebool -P ftpd_full_access 1 &>/dev/null
    sudo setsebool -P tftp_home_dir 1 &>/dev/null

    sudo semanage fcontext -a -t public_content_rw_t "/srv/ftp(/.*)?" 2>/dev/null
    sudo restorecon -R /srv/ftp 2>/dev/null

    if ! grep -q "/sbin/nologin" /etc/shells; then
        echo "/sbin/nologin" | sudo tee -a /etc/shells > /dev/null
    fi

    sudo systemctl restart vsftpd
    sudo systemctl enable vsftpd &>/dev/null
    echo -e "${C_EXITO}[v] Servidor FTP configurado correctamente.${C_RESET}"
}

establecer_puntos_montaje() {
    local usuario=$1
    local grupo=$2
    local home_dir="/home/$usuario"

    sudo mkdir -p "$home_dir/general" "$home_dir/$grupo" "$home_dir/$usuario"

    sudo chown root:root "$home_dir"
    sudo chmod 555 "$home_dir"

    sudo chown "$usuario:$usuario" "$home_dir/$usuario"
    sudo chmod 700 "$home_dir/$usuario"

    sudo umount "$home_dir/general" 2>/dev/null
    sudo umount "$home_dir/reprobados" 2>/dev/null
    sudo umount "$home_dir/recursadores" 2>/dev/null

    sudo mount --bind /srv/ftp/publico "$home_dir/general"
    sudo mount --bind /srv/ftp/grupos/$grupo "$home_dir/$grupo"
}

dar_alta_usuario() {
    local user=$1
    local pass=$2
    local group=$3

    if [[ -z "$user" || -z "$pass" ]]; then
        echo -e "${C_ERROR}[!] Error: Usuario y contrasena obligatorios.${C_RESET}"
        return
    fi

    if id "$user" &>/dev/null; then
        echo -e "${C_ERROR}[!] Error: El usuario '$user' ya existe.${C_RESET}"
        return
    fi

    sudo useradd -m -s /sbin/nologin "$user"
    echo "$user:$pass" | sudo chpasswd
    sudo usermod -aG grupo-ftp,"$group" "$user"

    establecer_puntos_montaje "$user" "$group"

    if ! grep -q "^/srv/ftp/publico /home/$user/general " /etc/fstab; then
        echo "/srv/ftp/publico /home/$user/general none bind 0 0" | sudo tee -a /etc/fstab > /dev/null
    fi
    if ! grep -q "^/srv/ftp/grupos/$group /home/$user/$group " /etc/fstab; then
        echo "/srv/ftp/grupos/$group /home/$user/$group none bind 0 0" | sudo tee -a /etc/fstab > /dev/null
    fi

    echo -e "${C_EXITO}[v] Usuario '$user' creado en el grupo '$group'.${C_RESET}"
}

mover_usuario_grupo() {
    local user=$1
    local n_group=$2

    if ! id "$user" &>/dev/null; then
        echo -e "${C_ERROR}[!] Error: Usuario no existe.${C_RESET}"
        return
    fi

    local grupo_actual=""
    if id -nG "$user" | grep -qw "reprobados"; then grupo_actual="reprobados"; fi
    if id -nG "$user" | grep -qw "recursadores"; then grupo_actual="recursadores"; fi

    if [[ "$grupo_actual" == "$n_group" ]]; then
        echo -e "${C_ERROR}[!] Error: El usuario ya esta en el grupo $n_group.${C_RESET}"
        return
    fi

    if [[ -n "$grupo_actual" ]]; then
        sudo gpasswd -d "$user" "$grupo_actual" &>/dev/null
    fi
    sudo usermod -aG "$n_group" "$user"

    sudo umount "/home/$user/reprobados" 2>/dev/null
    sudo umount "/home/$user/recursadores" 2>/dev/null
    sudo rm -rf "/home/$user/reprobados" "/home/$user/recursadores"

    sudo sed -i "\|/home/$user/reprobados|d" /etc/fstab
    sudo sed -i "\|/home/$user/recursadores|d" /etc/fstab

    if ! grep -q "^/srv/ftp/grupos/$n_group /home/$user/$n_group " /etc/fstab; then
        echo "/srv/ftp/grupos/$n_group /home/$user/$n_group none bind 0 0" | sudo tee -a /etc/fstab > /dev/null
    fi

    establecer_puntos_montaje "$user" "$n_group"
    echo -e "${C_EXITO}[v] Usuario '$user' movido al grupo '$n_group'.${C_RESET}"
}

eliminar_usuario() {
    local user=$1
    local home_dir="/home/$user"

    if ! id "$user" &>/dev/null; then
        echo -e "${C_ERROR}[!] Error: Usuario no existe.${C_RESET}"
        return
    fi

    sudo pkill -u "$user" 2>/dev/null

    for punto in "$home_dir/general" "$home_dir/reprobados" "$home_dir/recursadores"; do
        if mountpoint -q "$punto"; then
            sudo umount "$punto" 2>/dev/null || sudo umount -l "$punto" 2>/dev/null
        fi
    done

    sudo sed -i "\|/home/$user/general|d" /etc/fstab
    sudo sed -i "\|/home/$user/reprobados|d" /etc/fstab
    sudo sed -i "\|/home/$user/recursadores|d" /etc/fstab

    sudo userdel -r "$user" &>/dev/null

    if [ -d "$home_dir" ]; then
        sudo rm -rf "$home_dir"
    fi

    echo -e "${C_EXITO}[v] Usuario '$user' eliminado por completo.${C_RESET}"
}

mostrar_resumen_usuarios() {
    echo -e "\n${C_TITULO}=== LISTADO DE USUARIOS FTP ===${C_RESET}"
    printf "${C_INFO}%-20s | %-15s${C_RESET}\n" "NOMBRE DE USUARIO" "GRUPO ASIGNADO"
    echo "----------------------------------------"

    users_list=$(awk -F: '$7=="/sbin/nologin" && $3>=1000 {print $1}' /etc/passwd)

    if [ -z "$users_list" ]; then
        echo "No hay usuarios."
    else
        for u in $users_list; do
            if id -nG "$u" | grep -qw "reprobados"; then
                gr="reprobados"
            elif id -nG "$u" | grep -qw "recursadores"; then
                gr="recursadores"
            else
                gr="Sin asignar"
            fi
            printf "%-20s | %-15s\n" "$u" "$gr"
        done
    fi
    echo "----------------------------------------"
}

menu_principal() {
    if ! systemctl is-active --quiet vsftpd; then
        preparar_entorno_ftp
    fi

    while true; do
        clear
        echo -e "\n${C_TITULO}=== PANEL DE ADMINISTRACION FTP (FEDORA VSFTPD) ===${C_RESET}"
        echo -e " [1] ${C_INFO}Instalar componentes FTP${C_RESET}"
        echo -e " [2] ${C_INFO}Crear usuarios${C_RESET}"
        echo -e " [3] ${C_INFO}Cambiar grupo de usuario${C_RESET}"
        echo -e " [4] ${C_INFO}Eliminar usuario${C_RESET}"
        echo -e " [5] ${C_INFO}Ver usuarios registrados${C_RESET}"
        echo -e " [0] ${C_ERROR}Salir${C_RESET}"
        echo "---------------------------------------"
        read -p "Elige una opcion: " opt

        case $opt in
            1) preparar_entorno_ftp ;;
            2)
                echo -e "\n${C_TITULO}=== CREAR USUARIOS FTP ===${C_RESET}"
                read -p "Cuantos usuarios deseas crear?: " total
                if [[ ! "$total" =~ ^[0-9]+$ ]] || [[ "$total" -le 0 ]]; then
                    echo -e "${C_ERROR}Cantidad invalida.${C_RESET}"
                else
                    for (( i=1; i<=total; i++ )); do
                        echo ""
                        read -p "Nombre de usuario $i: " u_name
                        while true; do
                            read -s -p "Contrasena: " u_pass; echo
                            if [ -n "$u_pass" ]; then break; fi
                            echo -e "${C_ERROR}La contrasena no puede estar vacia.${C_RESET}"
                        done
                        read -p "Grupo (1: reprobados | 2: recursadores): " u_group
                        [[ "$u_group" == "1" ]] && grp="reprobados" || grp="recursadores"
                        dar_alta_usuario "$u_name" "$u_pass" "$grp"
                    done
                fi
                ;;
            3)
                echo -e "\n${C_TITULO}=== CAMBIAR USUARIO DE GRUPO FTP ===${C_RESET}"
                read -p "Nombre del usuario: " u_name
                read -p "Nuevo Grupo (1: reprobados | 2: recursadores): " u_group
                [[ "$u_group" == "1" ]] && grp="reprobados" || grp="recursadores"
                mover_usuario_grupo "$u_name" "$grp"
                ;;
            4)
                echo -e "\n${C_TITULO}=== ELIMINAR USUARIOS FTP ===${C_RESET}"
                read -p "Nombre del usuario a eliminar: " u_name
                read -p "Estas seguro de eliminar a '$u_name'? Todo su FTP se borrara (s/n): " confirmar
                if [[ "$confirmar" == "s" || "$confirmar" == "S" ]]; then
                    eliminar_usuario "$u_name"
                fi
                ;;
            5) mostrar_resumen_usuarios ;;
            0) exit 0 ;;
            *) echo -e "${C_ERROR}Opcion no valida.${C_RESET}" ;;
        esac
        echo ""
        read -p "Presiona ENTER para continuar..."
    done
}

menu_principal
