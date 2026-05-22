# Manual runbook from the validated Raspberry Pi

このメモは `scripts/setup-raspi.sh` の元になった手作業の要約です。公開リポジトリに置けるよう、実環境の ID や endpoint は placeholder にしています。

## Validated environment

- Raspberry Pi: `<raspberry-pi-host-or-ip>`
- Cellular interface used for Krypton: `wwan1`
- IMSI: `<imsi>`
- SORACOM group: `<soracom-group-name>`
- AWS region: `ap-northeast-1`
- AWS IoT data endpoint: `<aws-iot-data-endpoint>`
- AWS IoT credential provider endpoint: `<aws-iot-credential-provider-endpoint>`
- Greengrass role alias: `GreengrassV2TokenExchangeCoreDeviceRoleAlias`

## Result

- AWS IoT Thing: `<thing-name-from-krypton>`
- Certificate ID: `<certificate-id-from-krypton>`
- Greengrass Nucleus: `2.17.0`
- Greengrass service: `active` and `enabled`
- Greengrass Core device status: `HEALTHY`

## Important observation

This flow used SORACOM Air route authentication against:

```text
https://krypton.soracom.io:8036/v1/provisioning/aws/iot/bootstrap
```

It did not use SORACOM Endorse SIM authentication.
