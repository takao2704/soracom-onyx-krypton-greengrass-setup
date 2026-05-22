# soracom-onyx-krypton-greengrass-setup

Soracom Onyx を挿入した Raspberry Pi で SORACOM Krypton の回線認証を使い、AWS IoT のデバイス証明書を払い出して AWS IoT Greengrass Core v2 をセットアップするためのスクリプトです。

このリポジトリは、Raspberry Pi 側の作業をできるだけ 1 本のセットアップスクリプトに寄せています。AWS IoT policy、Greengrass token exchange role alias、SORACOM Krypton group 設定などのクラウド側準備は事前に実施してください。

## 何をするか

`scripts/setup-raspi.sh` は Raspberry Pi 上で以下を実行します。

- NetworkManager / ModemManager / Java / unzip / curl などをインストール
- Soracom Onyx の EG25-G modem を NetworkManager の GSM device として検出
- `soracom-<device>` 形式の NetworkManager connection profile を作成
- SORACOM サービス向け route を NetworkManager dispatcher に追加
- SORACOM Krypton bootstrap API を SORACOM Air 回線経由で呼び出し、AWS IoT 証明書を保存
- Krypton 証明書を Greengrass Core 用の配置にコピー
- Greengrass Nucleus をダウンロードし、manual provisioning で systemd service として起動

## 認証方式

この手順は SORACOM Air の回線認証を使います。

- 使用する endpoint: `https://krypton.soracom.io:8036/v1/provisioning/aws/iot/bootstrap`
- 使用しないもの: SORACOM Endorse の SIM 認証

## 前提

- Raspberry Pi OS / Debian 系 OS
- Soracom Onyx が Raspberry Pi に挿入済み
- SIM は `soracom.io` APN で通信できる状態
- 対象 SIM の group に SORACOM Krypton for AWS IoT が設定済み
- Krypton がアタッチする AWS IoT policy に Greengrass Core と token exchange 用の権限が含まれていること
- Greengrass token exchange role alias が作成済み

クラウド側の準備例は [docs/cloud-setup.md](docs/cloud-setup.md) を参照してください。

## Raspberry Pi 側の実行

設定ファイルを作成します。

```bash
cp examples/device.env.example device.env
vi device.env
```

最低限、以下を設定します。

```bash
AWS_IOT_DATA_ENDPOINT="xxxxxxxxxxxxxx-ats.iot.ap-northeast-1.amazonaws.com"
AWS_IOT_CRED_ENDPOINT="xxxxxxxxxxxxxx.credentials.iot.ap-northeast-1.amazonaws.com"
GREENGRASS_ROLE_ALIAS="GreengrassV2TokenExchangeCoreDeviceRoleAlias"
```

Raspberry Pi 上で実行します。

```bash
sudo bash scripts/setup-raspi.sh --env ./device.env
```

複数の Onyx / cellular interface がある場合は、Krypton に使う interface を明示できます。

```bash
sudo bash scripts/setup-raspi.sh --env ./device.env --interface wwan1
```

## 動作確認

Raspberry Pi 上で Greengrass service を確認します。

```bash
systemctl is-active greengrass
systemctl is-enabled greengrass
sudo tail -n 120 /greengrass/v2/logs/greengrass.log
```

AWS 側で Core device を確認します。

```bash
aws greengrassv2 get-core-device \
  --core-device-thing-name <thing-name> \
  --region ap-northeast-1
```

正常な場合、Core device status は `HEALTHY` になります。

## 実機で確認した構成

このスクリプト化の元になった検証では、以下の構成で動作確認しました。

- Raspberry Pi 4 / Debian 13 / arm64
- Soracom Onyx / EG25-G
- NetworkManager device: `cdc-wdm1`
- network interface: `wwan1`
- Greengrass Nucleus: `2.17.0`
- Greengrass Core device status: `HEALTHY`

実際の手作業ログは [docs/manual-runbook.md](docs/manual-runbook.md) に整理しています。

