### This SCript works in the assumption that the bond0 and bond 1 is configured along with the client and backup vlan for Mt Sinai setup

#!/bin/bash

# Define bond details
BONDS=("bond0" "bond1")

# Fetch UUIDs for the bonds
declare -A BOND_UUIDS
for BOND in "${BONDS[@]}"; do
  BOND_UUID=$(nmcli -t -f NAME,UUID connection show | grep "^$BOND" | cut -d: -f2)
  if [[ -z "$BOND_UUID" ]]; then
    echo "Error: Bond master $BOND not found. Exiting."
    exit 1
  fi
  BOND_UUIDS["$BOND"]="$BOND_UUID"
  echo "Bond Master: $BOND, UUID: ${BOND_UUIDS[$BOND]}"
done

# Fetch eligible Ethernet devices
ETH_DEVICES=$(ip link | grep -i mtu | grep -v "NO-CARRIER" | cut -d: -f2 | grep -v bond | grep -v vlan | grep -v lo | awk '{$1=$1;print}')

if [[ -z "$ETH_DEVICES" ]]; then
  echo "No eligible Ethernet devices found. Exiting."
  exit 1
fi

echo "Found Ethernet devices: $ETH_DEVICES"

# Allocate devices to bonds alternately
BOND_INDEX=0
for DEVICE in $ETH_DEVICES; do
  # Trim whitespace from device name
  DEVICE=$(echo "$DEVICE" | xargs)

  # Select the current bond
  CURRENT_BOND=${BONDS[$BOND_INDEX]}
  CURRENT_BOND_UUID=${BOND_UUIDS[$CURRENT_BOND]}

  # Generate a unique connection name
  CONNECTION_NAME="$DEVICE"

  # Create a new connection for the device
  nmcli connection add type ethernet ifname "$DEVICE" con-name "$CONNECTION_NAME" master "$CURRENT_BOND" slave yes

  # Fetch the UUID of the newly created connection
  CONNECTION_UUID=$(nmcli -t -f NAME,UUID connection show | grep "^$CONNECTION_NAME" | cut -d: -f2)

  # Verify if connection was created successfully
  if [[ -z "$CONNECTION_UUID" ]]; then
    echo "Error: Failed to create connection for device $DEVICE. Skipping."
    continue
  fi

  echo "Created connection for $DEVICE with UUID $CONNECTION_UUID, assigned to $CURRENT_BOND."

  # Update the ifcfg file with the required entries
  IFCFG_FILE="/etc/sysconfig/network-scripts/ifcfg-$DEVICE"
  cat > "$IFCFG_FILE" << EOF
MTU=9000
TYPE=Ethernet
NAME=$CONNECTION_NAME
UUID=$CONNECTION_UUID
DEVICE=$DEVICE
ONBOOT=yes
MASTER_UUID=$CURRENT_BOND_UUID
MASTER=$CURRENT_BOND
SLAVE=yes
EOF

  echo "Configuration written to $IFCFG_FILE."

  # Toggle the bond index to alternate bonds
  BOND_INDEX=$(( (BOND_INDEX + 1) % ${#BONDS[@]} ))
done

echo "All devices processed and assigned alternately to bonds."
