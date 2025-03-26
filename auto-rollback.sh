#!/bin/bash

# Parametros
project="$(System.TeamProject)"
patToken="$(SECRET_PAT_TOKEN)"
org=$(echo "$(System.TeamFoundationCollectionUri)" | awk -F'/' '{print $4}')

# Verificar token PAT
[ -z "$patToken" ] && { echo "Error: No se proporciono el token PAT."; exit 1; }

# Funcion para llamadas API
# Esta función hace la llamada una sola vez y emite dos líneas:
# la primera con el cuerpo JSON y la segunda con el codigo HTTP.
call_api() {
    local method=$1 url=$2 data=$3
    curl -s -w "\n%{http_code}" -X "$method" "$url" \
         -H "Authorization: Bearer $patToken" \
         -H "Content-Type: application/json" ${data:+-d "$data"}
}

# Validar token con una llamada API
validation_url="https://vsrm.dev.azure.com/$org/$project/_apis/release/releases?api-version=7.1"
validation_result=$(call_api GET "$validation_url")
validation_code=$(echo "$validation_result" | tail -n1)
validation_json=$(echo "$validation_result" | sed '$d')
[ "$validation_code" -ne 200 ] && { echo "Error: Token invalido o permisos insuficientes."; exit 1; }

# Obtener releases del pipeline
releases_url="https://vsrm.dev.azure.com/$org/$project/_apis/release/releases?definitionId=$(releaseDefinitionId)&\$expand=artifacts&api-version=7.1"
releases_result=$(call_api GET "$releases_url")
releases_code=$(echo "$releases_result" | tail -n1)
releases_json=$(echo "$releases_result" | sed '$d')
[ "$releases_code" -ne 200 ] && { echo "Error: Fallo al obtener los releases."; exit 1; }

# Validar si solo existe "Release-1"
if [ "$(echo "$releases_json" | jq '.value | length')" -eq 1 ] && \
   [ "$(echo "$releases_json" | jq -r '.value[0].name')" = "Release-1" ]; then
    echo "Error: Solo se encontro 'Release-1'."
    exit 1
fi

# Obtener ID del release a hacer rollback
release_id=$(echo "$releases_json" | jq -r --arg rn "$(rollback)" '.value[] | select(.name == $rn) | .id')
[ -z "$release_id" ] && { echo "Error: No se encontro el release $(rollback)."; exit 1; }

# Obtener detalles del release (llamada unica)
release_detail_url="https://vsrm.dev.azure.com/$org/$project/_apis/release/releases/$release_id?api-version=7.1"
detail_result=$(call_api GET "$release_detail_url")
detail_code=$(echo "$detail_result" | tail -n1)
detail_json=$(echo "$detail_result" | sed '$d')
[ "$detail_code" -ne 200 ] && { echo "Error: Fallo al obtener detalles del release."; exit 1; }

# Validar antigüedad del release
created_on=$(echo "$detail_json" | jq -r '.createdOn')
if [ -n "$created_on" ]; then
    created_on_sec=$(date -u -d "$(echo "$created_on" | sed 's/T/ /; s/\..*Z//')" +%s 2>/dev/null)
    if [ -n "$created_on_sec" ]; then
        diff_days=$(( ( $(date +%s) - created_on_sec ) / 86400 ))
        remaining_days=$((30 - diff_days))
        [ "$diff_days" -gt 20 ] && echo "Advertencia: La retencion del release expirara pronto. Dias restantes: $remaining_days."
        echo "Numero de dias del release de rollback => $diff_days"
    else
        echo "Advertencia: Formato de fecha invalido: $created_on"
    fi
else
    echo "Advertencia: No se pudo obtener la fecha de creacion."
fi

# Obtener entornos exitosos y activar redeploy
# Usamos los detalles del release en lugar de "$response"
for environmentId in $(echo "$detail_json" | jq -r '.environments[] | select(.status=="succeeded") | .id'); do
    API_URL="https://vsrm.dev.azure.com/$org/$project/_apis/Release/releases/$release_id/environments/$environmentId?api-version=7.1"
    patch_result=$(call_api PATCH "$API_URL" '{"status": "inProgress"}')
    patch_code=$(echo "$patch_result" | tail -n1)
    [ "$patch_code" -ne 200 ] && { echo "Error: Fallo al activar redeploy en $environmentId. Codigo: $patch_code"; continue; }
    sleep 1
done
