#!/bin/bash

#Taking backup
mkdir /root/confignetworkbackup/
cp /etc/sysconfig/network-scripts/* /root/confignetworkbackup/
echo "The network files are backedup successfully"

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
ETH_DEVICES=($(ip link | grep -i mtu | grep -v "NO-CARRIER" | cut -d: -f2 | grep -v bond | grep -v vlan | grep -v lo | awk '{$1=$1;print}'))

if [[ ${#ETH_DEVICES[@]} -lt 4 ]]; then
  echo "Error: At least 4 eligible Ethernet devices are required. Found ${#ETH_DEVICES[@]}. Exiting."
  exit 1
fi

echo "Found Ethernet devices: ${ETH_DEVICES[*]}"

# Define device to bond mapping
DEVICE_TO_BOND=("bond0" "bond1" "bond1" "bond0")

# Loop through first 4 devices and assign according to the mapping
for i in {0..3}; do
  DEVICE="${ETH_DEVICES[$i]}"
  EXPECTED_BOND="${DEVICE_TO_BOND[$i]}"
  EXPECTED_BOND_UUID="${BOND_UUIDS[$EXPECTED_BOND]}"
  CONNECTION_NAME="$DEVICE"

  # Find current connection (if exists)
  EXISTING_CON=$(nmcli -t -f DEVICE,NAME connection show --active | grep "^$DEVICE:" | cut -d: -f2)

  # Get current master bond
  CURRENT_MASTER=$(nmcli -g connection.master connection show "$EXISTING_CON" 2>/dev/null)

  if [[ "$CURRENT_MASTER" == "$EXPECTED_BOND" ]]; then
    echo "Device $DEVICE is already correctly assigned to $EXPECTED_BOND. Skipping."
    continue
  fi

  echo "Device $DEVICE is NOT assigned to $EXPECTED_BOND. Reconfiguring..."

  # Delete existing connection if it exists
  if [[ -n "$EXISTING_CON" ]]; then
    echo "Deleting existing connection $EXISTING_CON for $DEVICE."
    nmcli connection delete "$EXISTING_CON"
  fi

  # Backup ifcfg file if exists
  IFCFG_FILE="/etc/sysconfig/network-scripts/ifcfg-$DEVICE"
  if [[ -f "$IFCFG_FILE" ]]; then
    BACKUP_FILE="${IFCFG_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
    echo "Backing up $IFCFG_FILE to $BACKUP_FILE"
    cp "$IFCFG_FILE" "$BACKUP_FILE"
  fi

  # Create new slave connection
  nmcli connection add type ethernet ifname "$DEVICE" con-name "$CONNECTION_NAME" master "$EXPECTED_BOND"

  # Get the new UUID
  CONNECTION_UUID=$(nmcli -t -f NAME,UUID connection show | grep "^$CONNECTION_NAME" | cut -d: -f2)

  if [[ -z "$CONNECTION_UUID" ]]; then
    echo "Error: Failed to create connection for $DEVICE. Skipping."
    continue
  fi

  echo "Created connection for $DEVICE with UUID $CONNECTION_UUID, assigned to $EXPECTED_BOND."

  # Write new ifcfg file
  cat > "$IFCFG_FILE" << EOF
TYPE=Ethernet
NAME=$CONNECTION_NAME
UUID=$CONNECTION_UUID
DEVICE=$DEVICE
ONBOOT=yes
MASTER_UUID=$EXPECTED_BOND_UUID
MASTER=$EXPECTED_BOND
SLAVE=yes
EOF

  echo "Configuration written to $IFCFG_FILE."
done

echo "Device bonding verification, correction, and backups completed."
