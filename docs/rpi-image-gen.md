# rpi-image-gen base image build

## 目的

KRGG のゼロタッチ用ベースイメージを Raspberry Pi 実機なしで作ります。ベースイメージ作成は Raspberry Pi 公式の `rpi-image-gen` に一本化し、実行環境だけを OS ごとに切り替えます。

このイメージに焼くのは OS 依存物だけです。Krypton / Greengrass provisioning の payload は、従来通り SD カード書き込み後に boot partition へ注入します。

## 入るもの

[image/rpi-image-gen/layer/krgg-zero-touch-base.yaml](../image/rpi-image-gen/layer/krgg-zero-touch-base.yaml) が以下を rootfs に追加します。

- `network-manager`
- `modemmanager`
- `usb-modeswitch`
- `net-tools`
- `default-jdk-headless`
- `unzip`
- `curl`
- `ca-certificates`
- `python3`
- `usbutils`
- `/opt/krgg/greengrass-nucleus.zip`

また、NetworkManager / ModemManager を enable します。

## ビルド

共通入口は [tools/build-rpi-image-gen.sh](../tools/build-rpi-image-gen.sh) です。

```bash
tools/build-rpi-image-gen.sh
```

`--mode auto` がデフォルトです。

| Host OS | auto の動作 |
| --- | --- |
| macOS | Docker Desktop の Debian container 内で `rpi-image-gen` を実行 |
| Linux | host 上で `rpi-image-gen` を native 実行 |
| Windows WSL2 | WSL2 の Debian / Ubuntu 上で native 実行 |

macOS では Docker Desktop を起動してから実行します。Linux / WSL2 の native mode では、初回に `sudo` で rpi-image-gen の build dependencies をインストールします。依存関係を事前に用意済みの場合は `--skip-install-deps` を指定できます。

Greengrass Nucleus の同梱バージョンは build 時に指定できます。デフォルトは `2.17.0` です。

```bash
tools/build-rpi-image-gen.sh --nucleus-version 2.17.0
```

実行方式を明示する場合は以下です。

```bash
tools/build-rpi-image-gen.sh --mode docker --nucleus-version 2.17.0
tools/build-rpi-image-gen.sh --mode native --nucleus-version 2.17.0
```

初回は以下を行うため時間がかかります。

- `.cache/rpi-image-gen` へ `rpi-image-gen` を clone
- rpi-image-gen の build dependencies を install
- `image/rpi-image-gen/config/krgg-pi4-trixie.yaml` で image build

成果物は以下へコピーされます。

```text
dist/rpi-image-gen/
```

## 設定

デフォルト config は Raspberry Pi 4 / Trixie / arm64 です。

```text
image/rpi-image-gen/config/krgg-pi4-trixie.yaml
```

Raspberry Pi 5 用にする場合は config の `device.layer` を `rpi5` に変えます。

```yaml
device:
  layer: rpi5
```

Greengrass Nucleus zip を image に入れない場合は以下にします。後段の boot partition inject で `--nucleus-zip` を使う運用向けです。

```yaml
krgg:
  bundle_nucleus: n
```

Nucleus は初期 provisioning 後に AWS IoT Greengrass の deployment で OTA 更新できます。そのため、ベースイメージには検証済みの固定バージョンを入れ、更新は任意のタイミングで deployment に `aws.greengrass.Nucleus` の目的バージョンを明示して行います。

## SD カードへ書き込む

生成された image を Raspberry Pi Imager で SD カードへ書き込みます。

その後、mount された boot partition に first boot payload を注入します。

```bash
tools/inject-sd.sh --boot /Volumes/bootfs
```

この payload には以下が入ります。

- SORACOM 公式 `setup_eg25.sh`
- `setup-raspi.sh`
- `device.env`
- `krgg-provision.service`
- `krgg-provision.timer`
