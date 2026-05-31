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

Docker mode では、`rpi-image-gen` の build workdir をコンテナ内 filesystem に置きます。macOS の bind mount 上で rootfs を作ると、`mmdebstrap` や `apt-get update` が一時ファイルの close で `Input/output error` になることがあるためです。成果物だけを `dist/rpi-image-gen/` にコピーします。

SBOM 生成はデフォルトで無効にしています。キッティング用 image には不要で、`syft` の GitHub release 取得に依存して build が落ちることを避けるためです。必要な場合だけ `--enable-sbom` を指定します。

Docker Desktop の filesystem に 10 GiB 以上の空きが必要です。空きが少ない場合は、長い build に入る前にエラーで停止します。状況確認と整理は以下です。

```bash
docker system df
docker container prune
```

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

まず成果物を確認します。

```bash
ls -lh dist/rpi-image-gen/
```

Raspberry Pi Imager では以下のように選択します。

1. Device で対象 Raspberry Pi を選ぶ。標準 config は Raspberry Pi 4 用です。
2. OS で `Use Custom` を選び、`dist/rpi-image-gen/` の生成 image を選ぶ。
3. Storage で書き込み先の SD カードを選ぶ。複数の外部ドライブがある場合は容量を確認します。
4. OS customization はゼロタッチ provisioning には不要です。現地確認用に SSH や user を入れたい場合だけ設定します。
5. `Write` を実行し、verify 完了まで待ちます。

書き込み後、Mac で boot partition が mount されていることを確認します。

```bash
diskutil list
ls /Volumes
ls /Volumes/bootfs/cmdline.txt
```

Imager が SD カードを eject した場合は、SD カードを抜き差しして boot partition を mount し直します。

その後、mount された boot partition に first boot payload を注入します。

```bash
tools/inject-sd.sh
```

この payload には以下が入ります。

- SORACOM 公式 `setup_eg25.sh`
- `setup-raspi.sh`
- `device.env`
- `krgg-provision.service`
- `krgg-provision.timer`
