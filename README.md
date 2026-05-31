# soracom-onyx-krypton-greengrass-setup

Soracom Onyx を挿入した Raspberry Pi で SORACOM Krypton の回線認証を使い、AWS IoT のデバイス証明書を払い出して AWS IoT Greengrass Core v2 をセットアップするためのスクリプトです。

このリポジトリは、Raspberry Pi 側のセットアップ、ゼロタッチ配布用ベースイメージ作成、first boot payload 注入をまとめています。AWS IoT policy、Greengrass token exchange role alias、SORACOM Krypton group 設定などのクラウド側準備は事前に実施してください。

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

クラウド側の準備例は [docs/cloud-setup.md](docs/cloud-setup.md) を参照してください。現在の repository 構成になった背景と運用を考慮した技術選定は [docs/technical-decisions.md](docs/technical-decisions.md) にまとめています。

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

Thing 名は、未指定の場合に SORACOM Krypton group の `thingNamePattern` が使われます。ゼロタッチ運用では `KRYPTON_THING_NAME` を空にし、group 側で `takao-rpi-krypton-$imsi` のように SIM ごとに一意になる pattern を使います。

検証などで Raspberry Pi 個体名を明示したい場合だけ、デバイスごとに一意な Thing 名を指定してください。

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

ゼロタッチ運用では、まず依存パッケージ入りのベースイメージを `rpi-image-gen` で作ります。共通入口は以下です。

```bash
tools/build-rpi-image-gen.sh --nucleus-version 2.17.0
```

`--mode auto` がデフォルトです。macOS では Docker Desktop 上で `rpi-image-gen` を実行し、Linux / Windows WSL2 では native 実行します。明示する場合は以下です。

```bash
tools/build-rpi-image-gen.sh --mode docker --nucleus-version 2.17.0
tools/build-rpi-image-gen.sh --mode native --nucleus-version 2.17.0
```

成果物は `dist/rpi-image-gen/` にコピーされます。SD カードへの書き込み手順を含む詳細は [docs/rpi-image-gen.md](docs/rpi-image-gen.md) を参照してください。現在の repository 構成にした技術選定の意図は [docs/technology-selection.md](docs/technology-selection.md) にまとめています。

そのベースイメージを Raspberry Pi Imager で SD カードへ書いた後、boot partition に first boot 用 payload を注入できます。

```bash
tools/inject-sd.sh
```

`--boot` を省略すると、mount 済みで `cmdline.txt` を持つ boot partition 候補から対話的に選択できます。明示する場合は以下です。

```bash
tools/inject-sd.sh --boot /Volumes/bootfs
```

UART で現地デバッグする SD カードを作る場合は、payload 注入時に UART debug log を有効にします。

```bash
tools/inject-sd.sh --boot /Volumes/bootfs --uart-log
```

Greengrass Nucleus は検証済みの固定バージョンを使います。デフォルトは `2.17.0` です。ベースイメージではなく boot partition payload 側に同梱する場合は、payload 作成時に指定します。

```bash
tools/inject-sd.sh \
  --boot /Volumes/bootfs \
  --nucleus-zip ./greengrass-2.17.0.zip
```

デフォルトでは `cmdline.txt` に一度だけ `firstrun.sh` を起動する hook を追加します。これにより、Raspberry Pi Imager が作成した cloud-init の `user-data` を上書きしません。cloud-init を明示的に使う場合は以下のようにします。

```bash
tools/inject-sd.sh --boot /Volumes/bootfs --mode cloud-init --force-user-data
```

first boot では payload が `/opt/krgg` と systemd unit に展開され、`krgg-provision.timer` が `setup-raspi.sh` を再試行付きで実行します。成功後は `/var/lib/krgg/provisioned` が作成され、timer は無効化されます。

SSH できない状態でも切り分けできるように、first boot の status と失敗時の診断スナップショットは boot partition の `krgg/status/` にも書き出します。通信 session が上がらない場合は電源を落として SD カードを Mac に戻し、`/Volumes/bootfs/krgg/status/last-status` と `diag-*` を確認します。

`--uart-log` を使った場合は、boot partition の `config.txt` に `dtoverlay=disable-bt`、`enable_uart=1`、`init_uart_baud=115200` を設定し、GPIO14/15 に PL011 UART を割り当てます。Raspberry Pi の UART TXD0 / GPIO14 から first boot と provisioning のログも出力します。USB-UART 変換器は 3.3 V TTL、115200 bps で接続します。

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
