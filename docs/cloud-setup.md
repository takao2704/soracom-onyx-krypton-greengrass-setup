# Cloud-side setup

Raspberry Pi 側の `scripts/setup-raspi.sh` は AWS や SORACOM の管理 API 認証情報を持たない前提です。事前にクラウド側で以下を準備してください。

## 1. AWS IoT endpoint を確認する

```bash
aws iot describe-endpoint \
  --endpoint-type iot:Data-ATS \
  --region ap-northeast-1

aws iot describe-endpoint \
  --endpoint-type iot:CredentialProvider \
  --region ap-northeast-1
```

取得した値を Raspberry Pi 側の `device.env` に設定します。

```bash
AWS_IOT_DATA_ENDPOINT="xxxxxxxxxxxxxx-ats.iot.ap-northeast-1.amazonaws.com"
AWS_IOT_CRED_ENDPOINT="xxxxxxxxxxxxxx.credentials.iot.ap-northeast-1.amazonaws.com"
```

## 2. Greengrass token exchange role alias を用意する

既存の role alias がある場合はそれを使えます。

```bash
aws iot list-role-aliases --region ap-northeast-1
aws iot describe-role-alias \
  --role-alias GreengrassV2TokenExchangeCoreDeviceRoleAlias \
  --region ap-northeast-1
```

Raspberry Pi 側の `device.env` には role alias 名を設定します。

```bash
GREENGRASS_ROLE_ALIAS="GreengrassV2TokenExchangeCoreDeviceRoleAlias"
```

## 3. Krypton で証明書に付与する AWS IoT policy を用意する

Krypton の `policyName` には、Greengrass Core と token exchange に必要な権限を含む AWS IoT policy を指定します。

例:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "iot:Connect",
        "iot:Publish",
        "iot:Subscribe",
        "iot:Receive",
        "greengrass:*"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "iot:AssumeRoleWithCertificate",
      "Resource": "arn:aws:iot:ap-northeast-1:<aws-account-id>:rolealias/GreengrassV2TokenExchangeCoreDeviceRoleAlias"
    }
  ]
}
```

作成例:

```bash
aws iot create-policy \
  --policy-name GreengrassKryptonCorePolicy \
  --policy-document file://greengrass-krypton-core-policy.json \
  --region ap-northeast-1
```

既存の検証では、Krypton 発行後に追加で以下の policy を証明書へ attach しました。

- `GreengrassV2IoTThingPolicy`
- `GreengrassV2TokenExchangeCoreDeviceRoleAliasPolicy`

配布用には、Krypton が最初に attach する policy に上記相当の権限を含めておくと、Raspberry Pi 側だけで完結しやすくなります。

## 4. SORACOM Krypton group 設定を追加する

対象 SIM の groupId を確認します。

```bash
soracom subscribers get --imsi <imsi>
```

SORACOM group に Krypton 設定を追加します。

```bash
soracom groups put-config \
  --group-id <soracom-group-id> \
  --namespace SoracomKrypton \
  --body '[
    {
      "key": "enabled",
      "value": true
    },
    {
      "key": "AwsIot",
      "value": {
        "region": "ap-northeast-1",
        "credentialsId": "<soracom-aws-credentials-id-for-krypton>",
        "policyName": "GreengrassKryptonCorePolicy",
        "thingNamePattern": "takao-rpi-krypton-$imsi",
        "host": "<aws-iot-data-endpoint>"
      }
    }
  ]'
```

Krypton は group 単位の設定です。同じ group に属する SIM や Arc からもこの設定を利用できます。単一デバイスだけに適用したい場合は、専用 group を作って対象 SIM だけを所属させてください。

`thingNamePattern` はデバイスが Thing 名を指定しない場合の fallback です。ゼロタッチ運用では Raspberry Pi 側の `KRYPTON_THING_NAME` を空にし、`takao-rpi-krypton-$imsi` のように SIM ごとに一意になる pattern を group 側で設定します。検証用にハードウェア個体名を明示したい場合だけ、Raspberry Pi 側の `device.env` で `KRYPTON_THING_NAME` を設定してください。
