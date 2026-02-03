#!/bin/bash
echo "--- Nombre del equipo: $(hostname) ---"
IP=$(ip addr show enp0s8 | grep "inet " | awk '{print $2}' | cut -d/ -f1)
echo "IP actual: $IP"
echo "Disco:"
df -h / | awk 'NR==2 {print "Total: "$2" | Usado: "$3}'
