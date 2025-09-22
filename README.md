# 🔄 Restauración de Backup

## restaurar_backup_docker_completo.sh

Script complementario en Bash para restaurar un respaldo completo de entorno Docker generado por `backup_completo_semanal_docker.sh`. Restaura volúmenes, imágenes, configuraciones de contenedores y archivos de Docker Compose desde un backup específico.

## 📦 ¿Qué restaura?

- Todos los **volúmenes Docker** desde archivos comprimidos `.tar.gz`
- Todas las **imágenes Docker** desde archivos exportados `.tar`
- **Recreación de contenedores** usando las configuraciones guardadas (`docker inspect`)
- El volumen persistente de **Portainer**, si estaba presente en el backup
- Archivos de **Docker Compose** a la ruta `/data/compose`

## 🛠️ Requisitos

- Bash
- Docker
- Imagen Alpine (se descarga automáticamente si no está presente)
- Permisos adecuados (root o usuario en el grupo `docker`)
- Directorio de backup válido generado por el script de backup
- El script debe estar en `/usr/local/bin/`

## 📂 Estructura de entrada esperada

El script espera encontrar un directorio de backup con la siguiente estructura:

```
/var/backups/docker_backup_completo_YYYY-MM-DD/
├── docker_compose_files_YYYY-MM-DD.tar.gz
├── images/
│   ├── nombre__imagen__tag.tar
│   └── ...
├── inspect/
│   ├── contenedor_id.json
│   └── ...
├── portainer_data_YYYY-MM-DD.tar.gz
└── volumen_nombre_YYYY-MM-DD.tar.gz
```


## 🚀 Uso del Script

### Sintaxis básica:
```
sudo /usr/local/bin/restaurar_backup_docker_completo.sh [DIRECTORIO_BACKUP]
```

### Ejemplos de uso:

**Restaurar desde un backup específico:**
```
sudo /usr/local/bin/restaurar_backup_docker_completo.sh /var/backups/docker_backup_completo_2025-09-15
```


**Restaurar desde el backup más reciente (automático):**
```
sudo /usr/local/bin/restaurar_backup_docker_completo.sh
```


## ⚠️ Advertencias Importantes

- **Este script DETENDRÁ todos los contenedores existentes** durante el proceso de restauración
- **Eliminará volúmenes existentes** que coincidan con los nombres del backup
- **Sobrescribirá imágenes** si ya existen con el mismo nombre y tag
- **Reemplazará archivos de Docker Compose** en `/data/compose`
- Se recomienda hacer un backup del estado actual antes de restaurar

## 🔧 Proceso de Restauración

El script ejecuta los siguientes pasos en orden:

1. **Validación**: Verifica que el directorio de backup existe y contiene los archivos necesarios
2. **Detención**: Para todos los contenedores en ejecución
3. **Limpieza**: Elimina contenedores y volúmenes existentes que serán restaurados
4. **Restauración de imágenes**: Importa todas las imágenes Docker desde los archivos `.tar`
5. **Restauración de volúmenes**: Extrae y restaura todos los volúmenes desde archivos `.tar.gz`
6. **Restauración de Portainer**: Restaura el volumen de datos de Portainer (si existe)
7. **Restauración de Docker Compose**: Extrae archivos de compose a `/data/compose`
8. **Recreación de contenedores**: Crea contenedores usando las configuraciones guardadas
9. **Verificación**: Confirma que los contenedores se han recreado correctamente

## 📝 Logs y Monitoreo

Los logs de la restauración se guardan en:
```
/var/log/docker_restore.log
```

Para monitorear el proceso en tiempo real:
```
tail -f /var/log/docker_restore.log
```

## 🔍 Verificación Post-Restauración

Después de ejecutar el script, verificar:

Verificar volúmenes restaurados
```
docker volume ls
```
Verificar contenedores recreados
```
docker ps -a
```
Verificar archivos de Docker Compose
```
ls -la /data/compose/
```


## 🆘 Resolución de Problemas

### Error: "Directorio de backup no encontrado"
- Verificar que la ruta del directorio de backup es correcta
- Asegurarse de que el directorio contiene la estructura esperada

### Error: "Faltan archivos de backup"
- Verificar que el backup original se completó correctamente
- Comprobar que todos los archivos necesarios están presentes

### Contenedores no se inician correctamente
- Revisar los logs: `docker logs <container_name>`
- Verificar que las imágenes base están disponibles
- Comprobar que los volúmenes se restauraron correctamente

## 🔗 Scripts Relacionados

- **Backup**: `backup_completo_semanal_docker.sh` - Crea el backup completo
- **Logs**: Los logs de ambos scripts se almacenan en `/var/log/`

---

**Nota**: Este script está diseñado para trabajar en conjunto con `backup_completo_semanal_docker.sh`. Asegúrate de usar backups generados por ese script para garantizar la compatibilidad.

