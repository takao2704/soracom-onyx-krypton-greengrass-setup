# Technology selection

## 目的

この document は、現在の repository 構成でゼロタッチ Raspberry Pi kitting を運用するための技術選定をまとめます。手順の詳細は [zero-touch-kitting.md](zero-touch-kitting.md) と [rpi-image-gen.md](rpi-image-gen.md) に分け、ここでは「なぜその構成にしたか」を扱います。

## 運用前提

- 配布先の Raspberry Pi へ SSH できるとは限らない
- 初回起動時点では SIM が `soracom.io` APN で通信できる状態とは限らない
- SORACOM Onyx / EG25-G の初期化には `nmcli` / `mmcli` / `usb_modeswitch` が必要
- Krypton の device identity は SIM に寄せ、SORACOM group の `thingNamePattern` で AWS IoT Thing name を決めたい
- per-batch / per-environment の変更は、OS image を作り直さずに差し替えたい
- Mac を主な作業端末としつつ、Linux / Windows WSL2 でも同じ repository entrypoint で image を作りたい
- Raspberry Pi 実機を image 作成のためだけに起動しない運用にしたい

## 採用した構成

### rpi-image-gen でベースイメージを作る

OS 依存物は `rpi-image-gen` の layer として定義します。

- config: [image/rpi-image-gen/config/krgg-pi4-trixie.yaml](../image/rpi-image-gen/config/krgg-pi4-trixie.yaml)
- layer: [image/rpi-image-gen/layer/krgg-zero-touch-base.yaml](../image/rpi-image-gen/layer/krgg-zero-touch-base.yaml)
- runner: [tools/build-rpi-image-gen.sh](../tools/build-rpi-image-gen.sh)

ベースイメージに入れるものは、初回起動前に存在しないと困るものだけです。

- NetworkManager / ModemManager
- usb-modeswitch / usbutils / net-tools
- Java / unzip / curl / ca-certificates / python3
- Greengrass Nucleus zip

これにより、初回起動時に cellular 通信がまだ成立していない状態でも、Onyx setup と Krypton bootstrap へ進める前提が揃います。

Greengrass Nucleus は `latest` ではなく検証済みバージョンを build 時に指定します。デフォルトは `2.17.0` です。

```bash
tools/build-rpi-image-gen.sh --nucleus-version 2.17.0
```

初期 provisioning 後は `aws.greengrass.Nucleus` を含む Greengrass deployment で任意のサポート対象バージョンへ OTA 更新できます。そのため、量産時は「既知の固定バージョンで起動できること」を優先し、更新は fleet の deployment policy 側で制御します。

### build entrypoint は OS ごとに実行方式を切り替える

build command は [tools/build-rpi-image-gen.sh](../tools/build-rpi-image-gen.sh) に集約します。デフォルトの `--mode auto` は以下のように動きます。

| Host OS | 実行方式 |
| --- | --- |
| macOS | Docker Desktop の privileged Debian container 内で `rpi-image-gen` を実行 |
| Linux | host 上で `rpi-image-gen` を native 実行 |
| Windows WSL2 | WSL2 の Debian / Ubuntu 上で native 実行 |

macOS は Raspberry Pi OS の ext4 rootfs を直接扱うのに向いていません。`apt-get install`、`systemctl enable`、image filesystem 生成も Linux 前提です。そのため Mac では Docker Desktop の Linux VM を `rpi-image-gen` 実行環境として使います。

Linux / WSL2 では Docker を挟まず native 実行します。`rpi-image-gen` は Debian / Raspberry Pi OS 系 host を前提にしており、Linux であれば Docker の privileged mount や file ownership の癖を増やす必要がないためです。

### boot partition payload は別に注入する

Krypton / Greengrass provisioning の payload は、ベースイメージに固定せず boot partition へ注入します。

- injector: [tools/inject-sd.sh](../tools/inject-sd.sh)
- payload builder: [tools/build-payload.sh](../tools/build-payload.sh)
- first boot hook: [inject/boot/firstrun.sh](../inject/boot/firstrun.sh)
- first boot provisioner: [inject/payload/opt/krgg/firstboot-provision.sh](../inject/payload/opt/krgg/firstboot-provision.sh)
- config: [inject/payload/opt/krgg/device.env](../inject/payload/opt/krgg/device.env)

この分離により、以下は image を作り直さずに更新できます。

- AWS IoT endpoint
- Greengrass role alias
- SORACOM APN / route / timeout
- Krypton / Greengrass setup script
- first boot retry policy

### cmdline.txt hook を標準にする

first boot hook はデフォルトで `cmdline.txt` に `systemd.run=/boot/firmware/krgg/firstrun.sh` を追加します。

これにより、Raspberry Pi Imager が生成する `user-data` を上書きせずに済みます。cloud-init mode は残していますが、既存の `user-data` を置き換える必要があるため標準にはしていません。

### systemd timer で再試行する

provisioning は `krgg-provision.timer` から実行します。成功すると `/var/lib/krgg/provisioned` を作成し、timer を disable します。失敗時は 10 分ごとに再試行します。

初回起動時は modem 認識、SIM attach、SORACOM group 反映、AWS 側 policy 設定のタイミングに揺れがあるため、one-shot ではなく再試行前提にしています。

### SORACOM 公式 setup_eg25.sh を同梱する

fresh image では Onyx が `soracom.io` APN で通信できるとは限りません。そのため、SORACOM 公式の `setup_eg25.sh` を payload に含め、Krypton bootstrap 前に実行します。

ただし、この script 自体が `nmcli` / `mmcli` / `usb_modeswitch` を必要とするため、それらはベースイメージ側へ入れます。

### Thing name は IMSI 由来にする

ゼロタッチ運用では `KRYPTON_THING_NAME=""` を維持し、SORACOM Krypton group の `thingNamePattern` を使います。

```text
takao-rpi-krypton-$imsi
```

これにより、SIM ごとに AWS IoT Thing name と MQTT clientId が一意になります。検証用途で Raspberry Pi 個体名を明示したい場合だけ、`KRYPTON_THING_NAME` を設定します。

## 採用しなかった選択肢

### Raspberry Pi 実機で一度起動して clone する

最短で確実ですが、image 作成のたびに準備用 Raspberry Pi を起動する必要があり、再現性や自動化の観点では `rpi-image-gen` に劣ります。標準手順からは外し、base image の source of truth は `image/rpi-image-gen/` 配下の config / layer に寄せます。

### 全 OS で Docker 実行に統一する

手順の見た目は揃いますが、Linux / WSL2 でも Docker privileged 実行、mount namespace、file ownership の癖を持ち込むことになります。Linux では native 実行の方が `rpi-image-gen` の前提に近いため、Docker は macOS の Linux 実行環境として使う位置づけにします。

### macOS から rootfs を直接 mount / chroot する

macOS 標準では ext4 rootfs の扱いが弱く、loop device、mount namespace、chroot、systemd enable などの処理が Linux 前提です。Docker Desktop の Linux VM に寄せる方が単純です。

### pi-gen

`pi-gen` は Raspberry Pi OS image を作る実績ある選択肢ですが、この repository では「既存の Raspberry Pi OS 相当の構成に少量の layer を足す」用途です。より軽く declarative に layer を足せる `rpi-image-gen` を優先します。

### Raspberry Pi Imager content repository

content repository は、作成済み image を Raspberry Pi Imager から選びやすくする配布面の仕組みです。OS 依存パッケージを rootfs に入れる build 処理そのものは別途必要なので、まず `rpi-image-gen` で image を作ります。

### latest Nucleus を初回起動時に fetch する

`latest` を使うと、デバイスの初回起動日によって入る Nucleus version が変わります。また、初回 provisioning の成否が cellular download とその時点の最新版に依存します。量産時は build 時に検証済み version を指定し、OTA 更新は後段の deployment で制御します。

### 全 provisioning payload を image に固定する

payload まで image に焼くと、AWS endpoint、SORACOM group 運用、script 修正のたびに image 再作成が必要になります。OS 依存物は image、provisioning payload は boot partition 注入、という分離を維持します。

### per-device Thing name を image に焼く

image に個体識別子を持たせると量産時の事故要因になります。SIM / IMSI を identity とし、Krypton group 側の `thingNamePattern` を source of truth にします。

## 変更時に触る場所

- OS 依存パッケージを変える: [image/rpi-image-gen/layer/krgg-zero-touch-base.yaml](../image/rpi-image-gen/layer/krgg-zero-touch-base.yaml)
- target device や image サイズを変える: [image/rpi-image-gen/config/krgg-pi4-trixie.yaml](../image/rpi-image-gen/config/krgg-pi4-trixie.yaml)
- first boot の retry / status / 実行順を変える: [inject/payload/opt/krgg/firstboot-provision.sh](../inject/payload/opt/krgg/firstboot-provision.sh)
- AWS / SORACOM / Greengrass の環境値を変える: [inject/payload/opt/krgg/device.env](../inject/payload/opt/krgg/device.env)
- SD カードへの注入方式を変える: [tools/inject-sd.sh](../tools/inject-sd.sh)

## 未検証事項

以下は repository 上の lint / 構文検査までは確認済みですが、end-to-end の full image build と焼き込み後の実機起動確認は別途必要です。

- `tools/build-rpi-image-gen.sh` による full image build
- 生成 image の Raspberry Pi Imager 書き込み
- boot partition inject 後の first boot provisioning
- Greengrass Core が `HEALTHY` になること
