#!/bin/bash
# Fix the generated docker-compose-ccaas.yaml file

if [ ! -f docker-compose-ccaas.yaml ]; then
    exit 0
fi

# Replace CHAINCODE_VERSION with CC_VERSION
sed -i.bak 's/\$CHAINCODE_VERSION/\$CC_VERSION/g' docker-compose-ccaas.yaml

# Replace CCID_SANDBOX with CCID_CDCS (for old naming) or CCID_CROSS-DEPT-CLAIMS with CCID_CROSS_DEPT_CLAIMS
sed -i.bak 's/\$CCID_SANDBOX/\$CCID_CDCS/g' docker-compose-ccaas.yaml
sed -i.bak 's/\$CCID_CROSS-DEPT-CLAIMS/\$CCID_CROSS_DEPT_CLAIMS/g' docker-compose-ccaas.yaml

# Replace sandbox-peer0 with cdcs-peer0 in service name
sed -i.bak 's/^  sandbox-peer0:/  cdcs-peer0:/' docker-compose-ccaas.yaml

# Add container_name after the service name (if not already present)
if ! grep -q "container_name:" docker-compose-ccaas.yaml || ! grep -q "container_name: cdcs-peer0" docker-compose-ccaas.yaml; then
    sed -i.bak '/^  cdcs-peer0:/a\
    container_name: cdcs-peer0' docker-compose-ccaas.yaml
fi

# Add external: true after byfn: in networks section (if not already present)
if ! grep -q "external: true" docker-compose-ccaas.yaml; then
    sed -i.bak '/^  byfn:/a\
    external: true' docker-compose-ccaas.yaml
fi

# Remove backup file
rm -f docker-compose-ccaas.yaml.bak

