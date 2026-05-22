# Zero-touch Raspberry Pi kitting

## 方針

初回起動時に SSH や既存 IP 接続へ頼らず、Soracom Onyx の cellular 回線だけで Krypton bootstrap と Greengrass Core 登録まで進めます。

fresh な Raspberry Pi OS は、SIM が `soracom.io` APN で通信できる状態とは限りません。さらに `setup_eg25.sh` を動かすには `nmcli` / `mmcli` / `usb_modeswitch` が先に必要です。そのため、以下のように責務を分けます。

- ベースイメージに固定するもの: NetworkManager、ModemManager、usb-modeswitch、net-tools、Java、unzip、curl、python3、usbutils、Greengrass Nucleus zip
- boot partition に注入するもの: `setup_eg25.sh`、`setup-raspi.sh`、`device.env`、systemd service / timer
- SORACOM group 側で決めるもの: Krypton の `thingNamePattern`

量産や配布では `KRYPTON_THING_NAME` を空にし、SORACOM Krypton group の `thingNamePattern` を使います。今回の想定値は以下です。

```text
takao-rpi-krypton-$imsi
```

これにより、SIM ごとに AWS IoT Thing name と MQTT clientId が一意になります。

## 1. ベースイメージを作る

準備用 Raspberry Pi を Ethernet / Wi-Fi などで apt と AWS の download endpoint に到達できる状態にし、この repository を置いて以下を実行します。

```bash
sudo tools/prepare-base-image.sh
```

このスクリプトは以下を実行します。

- `apt-get install` で固定依存パッケージをインストール
- NetworkManager / ModemManager を enable
- Greengrass Nucleus zip を `/opt/krgg/greengrass-nucleus.zip` に保存
- 必要コマンドが揃っているか検査

確認だけを行う場合は以下です。

```bash
tools/prepare-base-image.sh --check-only
```

Greengrass Nucleus zip を boot partition payload 側で同梱する運用にする場合は、ベースイメージ作成時の download を省略できます。

```bash
sudo tools/prepare-base-image.sh --skip-nucleus
```

準備が終わった SD カードを clone / capture し、配布用のベースイメージとして扱います。

## 2. per-batch 設定を確認する

boot partition へ注入される設定は [inject/payload/opt/krgg/device.env](../inject/payload/opt/krgg/device.env) です。

ゼロタッチ運用では以下を維持します。

```bash
KRGG_INSTALL_PACKAGES="false"
KRGG_REQUIRE_BASE_IMAGE_PREREQS="true"
KRGG_RUN_ONYX_SETUP="true"
KRYPTON_THING_NAME=""
```

`KRYPTON_THING_NAME=""` の場合、Krypton bootstrap request に thingName を指定しません。SORACOM group の `thingNamePattern` が使われます。

## 3. SD カードへ payload を注入する

ベースイメージを書き込んだ SD カードを Mac などに mount し、boot partition に payload を注入します。

```bash
tools/inject-sd.sh --boot /Volumes/bootfs
```

Greengrass Nucleus zip をベースイメージではなく payload 側へ入れる場合は以下です。

```bash
tools/inject-sd.sh \
  --boot /Volumes/bootfs \
  --nucleus-zip ./greengrass-nucleus-latest.zip
```

デフォルトでは `cmdline.txt` に `systemd.run=/boot/firmware/krgg/firstrun.sh` を追加します。Raspberry Pi Imager が作成した `user-data` を上書きしないため、Imager の Wi-Fi / user 作成設定と共存できます。

## 4. 初回起動で実行されること

1. `firstrun.sh` が boot partition の payload を `/` へ展開する
2. `krgg-provision.timer` が有効化される
3. timer が `/opt/krgg/firstboot-provision.sh` を実行する
4. base image prerequisites を検査する
5. SORACOM 公式 `setup_eg25.sh` が `soracom.io` APN の cellular profile を作る
6. `setup-raspi.sh` が Krypton bootstrap を実行し、AWS IoT 証明書を取得する
7. Greengrass Core を manual provisioning で systemd service として登録する
8. 成功後に `/var/lib/krgg/provisioned` を作成し、timer を disable する

失敗した場合、timer は 10 分ごとに再試行します。

## 5. 現地で見るログ

SSH できる場合は以下を確認します。

```bash
sudo cat /var/lib/krgg/last-status
sudo tail -n 200 /var/log/krgg-provision.log
sudo tail -n 120 /var/log/soracom-krypton-greengrass-setup.log
sudo journalctl -u krgg-provision.service -n 120 --no-pager
```

Greengrass 側は以下です。

```bash
systemctl is-active greengrass
systemctl is-enabled greengrass
sudo tail -n 120 /greengrass/v2/logs/greengrass.log
```

## 6. 失敗時の見立て

- `base image missing prerequisites`: ベースイメージに必要パッケージが入っていない。配布元イメージを作り直す。
- `Onyx setup failed or timed out`: modem が見えていない、SIM が未挿入、SIM が inactive、または radio / USB 認識の問題。
- `Krypton bootstrap failed`: SIM が対象 group に入っていない、Krypton group 設定がない、SORACOM service route が入っていない、または policy / credential 設定の問題。
- `greengrass.service is not active`: AWS IoT policy、token exchange role alias、Greengrass config、または Nucleus install の問題。
