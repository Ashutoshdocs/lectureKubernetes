az vm list -d --query "[?location=='centralindia'].{VM:name, RG:resourceGroup, State:powerState, Size:hardwareProfile.vmSize}" -o table

az vm list-usage -l centralindia --query "[?name.value=='cores'].{Used:currentValue, Limit:limit}" -o table
