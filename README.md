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

ゼロタッチ配布では、初回起動時に apt へ到達できるとは限らないため、依存パッケージのインストールはベースイメージ作成時に済ませます。boot partition へ注入する payload は、SORACOM Onyx 設定スクリプト、Krypton / Greengrass セットアップスクリプト、`device.env`、systemd unit だけを差し替える前提です。

## 認証方式

この手順は SORACOM Air の回線認証を使います。

- 使用する endpoint: `https://krypton.soracom.io:8036/v1/provisioning/aws/iot/bootstrap`
- 使用しないもの: SORACOM Endorse の SIM 認証

## 前提

- Raspberry Pi OS / Debian 系 OS
- Soracom Onyx が Raspberry Pi に挿入済み
- 手動実行の場合、SIM は `soracom.io` APN で通信できる状態
- ゼロタッチ実行の場合、ベースイメージに NetworkManager / ModemManager / usb-modeswitch / Java / unzip / curl などをインストール済み
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

複数の Raspberry Pi を同じ SIM / group 設定でプロビジョニングする場合は、デバイスごとに一意な Thing 名を指定してください。未指定の場合は、SORACOM Krypton group の `thingNamePattern` が使われます。

```bash
KRYPTON_THING_NAME="takao-rpi-krypton-rpi37"
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

## SD カードへの注入

ゼロタッチ運用では、まず依存パッケージ入りのベースイメージを作ります。ネットワークが使える準備用 Raspberry Pi で以下を一度実行し、その SD カードを clone / capture して配布用の元イメージにします。

```bash
sudo tools/prepare-base-image.sh
```

最低限の確認だけをする場合は以下です。

```bash
tools/prepare-base-image.sh --check-only
```

そのベースイメージを Raspberry Pi Imager で SD カードへ書いた後、Mac などで boot partition に first boot 用 payload を注入できます。

```bash
tools/inject-sd.sh --boot /Volumes/bootfs
```

Greengrass Nucleus zip を SD カードに同梱する場合は、payload 作成時に指定します。

```bash
tools/inject-sd.sh \
  --boot /Volumes/bootfs \
  --nucleus-zip ./greengrass-nucleus-latest.zip
```

デフォルトでは `cmdline.txt` に一度だけ `firstrun.sh` を起動する hook を追加します。これにより、Raspberry Pi Imager が作成した cloud-init の `user-data` を上書きしません。cloud-init を明示的に使う場合は以下のようにします。

```bash
tools/inject-sd.sh --boot /Volumes/bootfs --mode cloud-init --force-user-data
```

first boot では payload が `/opt/krgg` と systemd unit に展開され、`krgg-provision.timer` が `setup-raspi.sh` を再試行付きで実行します。成功後は `/var/lib/krgg/provisioned` が作成され、timer は無効化されます。

payload には SORACOM 公式の Onyx / EG25-G セットアップスクリプト `setup_eg25.sh` も含めています。fresh な Raspberry Pi OS では `soracom.io` APN で通信できる状態とは限らないため、first boot では先にこのスクリプトで cellular profile を作成し、その後に Krypton bootstrap と Greengrass install を実行します。ただし `nmcli` / `mmcli` / `usb_modeswitch` などは first boot 前にベースイメージへ入っている必要があります。元スクリプトは以下です。

```text
https://soracom-files.s3.amazonaws.com/connect/setup_eg25.sh
```

詳しい方針と運用手順は [docs/zero-touch-kitting.md](docs/zero-touch-kitting.md) を参照してください。

## 実機で確認した構成

このスクリプト化の元になった検証では、以下の構成で動作確認しました。

- Raspberry Pi 4 / Debian 13 / arm64
- Soracom Onyx / EG25-G
- NetworkManager device: `cdc-wdm1`
- network interface: `wwan1`
- Greengrass Nucleus: `2.17.0`
- Greengrass Core device status: `HEALTHY`

実際の手作業ログは [docs/manual-runbook.md](docs/manual-runbook.md) に整理しています。
