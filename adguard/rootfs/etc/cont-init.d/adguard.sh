#!/command/with-contenv bashio
# shellcheck disable=SC2207
# ==============================================================================
# Home Assistant Community Add-on: AdGuard Home
# Handles configuration
# ==============================================================================
readonly CONFIG="/data/adguard/AdGuardHome.yaml"
declare schema_version
declare -a interfaces
declare -a hosts
declare part
declare fd
declare a2

if ! bashio::fs.file_exists "${CONFIG}"; then
    mkdir -p /data/adguard
    cp /etc/adguard/AdGuardHome.yaml "${CONFIG}"
fi

port=$(bashio::addon.port "53/udp") \
  yq e --inplace '.dns.port = env(port)' "${CONFIG}" \
    || bashio::exit.nok 'Failed updating AdGuardHome DNS port'


# Bump schema version in case this is an upgrade path
schema_version=$(yq e '.schema_version // ""' "${CONFIG}")
if bashio::var.has_value "${schema_version+}"; then
    if (( schema_version == 7 )); then
        # Clean up old interface bind formats
        yq --inplace e 'del(.dns.bind_host)' "${CONFIG}" 
        yq --inplace e '.schema_version = 8' "${CONFIG}"
    fi

    # Warn if this is an upgrade from below schema version 7, skip further process
    if (( schema_version < 7 )); then
        # Ensure dummy value exists so AdGuard doesn't kill itself during migration
        yq --inplace e '.dns.bind_host = "127.0.0.1"' "${CONFIG}"
        bashio::warning
        bashio::warning "AdGuard Home needs to update its configuration schema"
        bashio::warning "you might need to restart he add-on once more to complete"
        bashio::warning "the upgrade process."
        bashio::warning
        bashio::exit.ok
    fi
else
    # No idea what the schema is, might be an old config?
    # Ensure dummy value exists so AdGuard doesn't kill itself during migration
    yq --inplace e '.dns.bind_host = "127.0.0.1"' "${CONFIG}"
fi

# Collect IP addresses
interfaces+=($(bashio::network.interfaces))
for interface in "${interfaces[@]}"; do
    hosts+=($(bashio::network.ipv4_address "${interface}"))
    hosts+=($(bashio::network.ipv6_address "${interface}"))
done
hosts+=($(bashio::addon.ip_address))

# Add interface to bind to, to AdGuard Home
yq --inplace e '.dns.bind_hosts = []' "${CONFIG}"
for host in "${hosts[@]}"; do
    # Empty host value? Skip it
    if ! bashio::var.has_value "${host}"; then
        continue
    fi

    if [[ "${host}" =~ .*:.* ]]; then
      # IPv6
      part="${host%%:*}"

      # The decimal values for 0xfd & 0xa2
      fd=$(( (0x$part) / 256 ))
      a2=$(( (0x$part) % 256 ))

      # fe80::/10 according to RFC 4193 -> Local link. Skip it
      if (( (fd == 254) && ( (a2 & 192) == 128) )); then
        continue
      fi
    else
      # IPv4
      part="${host%%.*}"

      # 169.254.0.0/16 according to RFC 3927 -> Local link. Skip it
      if (( part == 169 )); then
        continue
      fi
    fi

    host="${host%/*}" yq --inplace e \
      '.dns.bind_hosts += [env(host)]' "${CONFIG}" \
        || bashio::exit.nok 'Failed updating AdGuardHome host'
done
