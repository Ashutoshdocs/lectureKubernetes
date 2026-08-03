#!/bin/bash

echo "================================="
echo " CUSTOMER SUPPORT TOOL "
echo "================================="

read -p "Enter Customer Username: " USERNAME

echo
echo "Searching logs..."
echo

kubectl logs -l app=webapp | awk -v user="$(echo "$USERNAME" | tr '[:upper:]' '[:lower:]')" '

tolower($0) ~ "user="user {
    print prev
    print
    getline; print
    getline; print
    getline; print
}
{
    prev=$0
}
'
