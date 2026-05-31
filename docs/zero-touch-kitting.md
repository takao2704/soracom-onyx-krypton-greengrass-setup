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

`rpi-image-gen` でベースイメージを生成します。Raspberry Pi 実機を image 作成のためだけに起動する必要はありません。

```bash
tools/build-rpi-image-gen.sh --nucleus-version 2.17.0
```

`--mode auto` がデフォルトです。macOS では Docker Desktop 上で `rpi-image-gen` を実行し、Linux / Windows WSL2 では native 実行します。

成果物は以下へコピーされます。

```text
dist/rpi-image-gen/
```

詳細は [rpi-image-gen base image build](rpi-image-gen.md) を参照してください。技術選定の背景は [technology-selection.md](technology-selection.md) にまとめています。

## 2. SD カードへベースイメージを書き込む

Raspberry Pi Imager で、生成されたベースイメージを SD カードへ書き込みます。

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

## 3. per-batch 設定を確認する

boot partition へ注入される設定は [inject/payload/opt/krgg/device.env](../inject/payload/opt/krgg/device.env) です。

ゼロタッチ運用では以下を維持します。

```bash
KRGG_INSTALL_PACKAGES="false"
KRGG_REQUIRE_BASE_IMAGE_PREREQS="true"
KRGG_RUN_ONYX_SETUP="true"
KRYPTON_THING_NAME=""
```

`KRYPTON_THING_NAME=""` の場合、Krypton bootstrap request に thingName を指定しません。SORACOM group の `thingNamePattern` が使われます。

## 4. SD カードへ payload を注入する

ベースイメージを書き込んだ SD カードを Mac などに mount し、boot partition に payload を注入します。

```bash
tools/inject-sd.sh
```

`--boot` を省略すると、mount 済みで `cmdline.txt` を持つ boot partition 候補から対話的に選択できます。明示する場合は以下です。

```bash
tools/inject-sd.sh --boot /Volumes/bootfs
```

UART でデバッグする SD カードを作る場合は、payload 注入時に `--uart-log` を付けます。

```bash
tools/inject-sd.sh --boot /Volumes/bootfs --uart-log
```

これにより boot partition の `config.txt` に `enable_uart=1` を設定し、cmdline mode では `cmdline.txt` に `console=serial0,115200` を追加します。また、first boot と provisioning のログを `/dev/serial0` にも出力します。USB-UART 変換器は 3.3 V TTL、115200 bps で Raspberry Pi の TXD0 / GPIO14 と GND に接続します。

Greengrass Nucleus は検証済みの固定バージョンを使います。デフォルトは `2.17.0` です。ベースイメージではなく payload 側へ入れる場合は以下です。

```bash
tools/inject-sd.sh \
  --boot /Volumes/bootfs \
  --nucleus-zip ./greengrass-2.17.0.zip
```

デフォルトでは `cmdline.txt` に `systemd.run=/boot/firmware/krgg/firstrun.sh` を追加します。Raspberry Pi Imager が作成した `user-data` を上書きしないため、Imager の Wi-Fi / user 作成設定と共存できます。

## 5. 初回起動で実行されること

1. `firstrun.sh` が boot partition の payload を `/` へ展開する
2. `krgg-provision.timer` が有効化される
3. timer が `/opt/krgg/firstboot-provision.sh` を実行する
4. base image prerequisites を検査する
5. SORACOM 公式 `setup_eg25.sh` が `soracom.io` APN の cellular profile を作る
6. `setup-raspi.sh` が Krypton bootstrap を実行し、AWS IoT 証明書を取得する
7. Greengrass Core を manual provisioning で systemd service として登録する
8. 成功後に `/var/lib/krgg/provisioned` を作成し、timer を disable する

失敗した場合、timer は 10 分ごとに再試行します。

## 6. 現地で見るログ

cellular session が上がらず SSH できない場合は、Raspberry Pi の電源を落として SD カードを Mac に戻し、boot partition の status を確認します。

```bash
cat /Volumes/bootfs/krgg/status/last-status
tail -n 200 /Volumes/bootfs/krgg/status/provision.log
ls -1 /Volumes/bootfs/krgg/status/diag-*
```

UART debug log を有効にしている場合は、serial console 側にも同じ stage status と `setup-raspi.sh` の進行ログが流れます。

`diag-*` には失敗時点の `systemctl`、`NetworkManager` / `ModemManager`、`nmcli`、`mmcli -L`、`lsusb`、IP address / route、関連 journal、KRGG logs の snapshot が入ります。証明書や `device.env` はコピーしませんが、USB device や network 状態を含むため、外部共有前には内容を確認してください。

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

## 7. 失敗時の見立て

- `base image missing prerequisites`: ベースイメージに必要パッケージが入っていない。配布元イメージを作り直す。
- `Onyx setup failed or timed out`: modem が見えていない、SIM が未挿入、SIM が inactive、または radio / USB 認識の問題。
- `ONYX_SETUP_DONE` の後に失敗する: cellular profile 作成後に Krypton bootstrap または Greengrass setup へ進んでいる。`diag-*` の route、active connection、`soracom-krypton-greengrass-setup.log` を見る。
- `Krypton bootstrap failed`: SIM が対象 group に入っていない、Krypton group 設定がない、SORACOM service route が入っていない、または policy / credential 設定の問題。
- `greengrass.service is not active`: AWS IoT policy、token exchange role alias、Greengrass config、または Nucleus install の問題。
