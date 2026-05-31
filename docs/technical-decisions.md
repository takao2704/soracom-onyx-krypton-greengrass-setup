# 運用を考慮した技術選定

このドキュメントは、この repository が現在の `scripts/`、`tools/`、`inject/`、`docs/`、`examples/` 構成になっている理由をまとめたものです。主な前提は、Soracom Onyx を挿した Raspberry Pi を複数台配布し、現地で SSH や既存 LAN に頼らず SORACOM Krypton と AWS IoT Greengrass Core まで自己構成させる運用です。

## 運用上の制約

- fresh な Raspberry Pi OS は、起動直後に `soracom.io` APN で通信できるとは限らない。
- Krypton bootstrap は SORACOM Air 回線経由で成功させる必要があるため、Krypton より前に cellular profile と SORACOM サービス向け route が必要。
- 現地配布では inbound SSH、固定 IP、同一 LAN 接続を前提にしない。
- 複数台を同じ group 設定で払い出すため、AWS IoT Thing name / MQTT clientId はデバイスごとに一意でなければならない。
- public repository として配布するため、AWS / SORACOM の管理 API credential、証明書、tenant 固有 ID は repository に入れない。
- 失敗時は現地で電源再投入や電波回復を待つことがあるため、初回起動処理は一度失敗しても再試行できる必要がある。

## 採用した構成

### 1. Bash と OS 標準ツールを中心にする

`scripts/setup-raspi.sh`、`tools/*.sh`、`inject/boot/firstrun.sh` は Bash で実装しています。

理由:

- Raspberry Pi OS / Debian 系に標準的に入りやすく、first boot payload に追加 runtime を持ち込まなくてよい。
- `systemctl`、`nmcli`、`mmcli`、`ip`、`curl`、`tar` など OS 操作が中心で、Bash の方が実行環境を単純に保てる。
- boot partition への注入や systemd unit との接続が素直に書ける。

採用しなかったもの:

- Ansible: 現地で SSH 接続できる前提が強く、ゼロタッチ配布の前提と合わない。
- Python package 化: device 側 runtime や packaging の説明が増える割に、現状の処理は OS コマンド orchestration が中心。
- Docker / container: modem、NetworkManager、systemd、Greengrass service の host integration が主目的なので、container 境界が運用を複雑にする。

### 2. Onyx の回線確立は NetworkManager / ModemManager に寄せる

Soracom Onyx / EG25-G は、NetworkManager が認識した GSM device ごとに `soracom-<device>` connection profile を作ります。

理由:

- `cdc-wdmN` や `wwanN` が複数出る構成でも、device ごとに profile を分けると接続対象が明確になる。
- MBIM / QMI の違いを USB interface 数ではなく、Linux 上の `cdc-wdmN` / `wwanN` と NetworkManager の GSM device として扱える。
- `nmcli con up <profile> ifname <device>` の形にすると、複数 Onyx 構成で接続先を明示できる。

関連する実装:

- `scripts/setup-raspi.sh`: NetworkManager / ModemManager を使った手動・SSH 実行向け処理
- `inject/payload/opt/krgg/setup_eg25.sh`: fresh boot で先に APN を作るために同梱した SORACOM 公式 setup script

### 3. first boot で package install しない

ゼロタッチ運用では、`tools/prepare-base-image.sh` で固定依存パッケージをベースイメージに入れます。first boot 側は `KRGG_INSTALL_PACKAGES=false` とし、必要コマンドがなければ失敗として再試行に回します。

理由:

- APN 設定前は apt repository に到達できない可能性がある。
- cellular 接続が不安定な場所で package install を走らせると、失敗時の復旧が読みづらくなる。
- 固定依存はベースイメージに寄せ、batch ごとに変わる設定だけ boot partition payload で差し替える方が配布運用しやすい。

採用した分担:

- `tools/prepare-base-image.sh`: `network-manager`、`modemmanager`、`usb-modeswitch`、`default-jdk-headless`、`curl`、`python3` など固定依存
- `tools/build-payload.sh`: first boot payload の tarball 化
- `tools/inject-sd.sh`: SD カードの boot partition へ payload と起動 hook を注入
- `inject/payload/opt/krgg/firstboot-provision.sh`: 初回起動時の再試行可能な provisioning entrypoint

### 4. boot hook は `cmdline.txt` を標準にし、cloud-init は選択肢にする

`tools/inject-sd.sh` の標準モードは `cmdline.txt` に `systemd.run=/boot/firmware/krgg/firstrun.sh` を追加する方式です。cloud-init mode も用意していますが、明示的に指定した場合だけ使います。

理由:

- Raspberry Pi Imager が生成した `user-data` を上書きせず、ユーザー作成や Wi-Fi 設定と共存できる。
- boot partition だけを編集すればよく、Mac などから SD カードへ注入しやすい。
- 一度 payload を展開した後は systemd timer に移行できるため、boot hook は最小責務で済む。

cloud-init を標準にしない理由:

- 既存 `user-data` と衝突しやすい。
- 配布者が Raspberry Pi Imager の設定を使う運用と混ぜると、どちらが最終状態を作ったのか追いにくい。

### 5. Krypton は SORACOM Air 回線認証で使う

証明書払い出しは `https://krypton.soracom.io:8036/v1/provisioning/aws/iot/bootstrap` を SORACOM Air interface から呼び出す方式にしています。

理由:

- device に AWS credential や SORACOM API credential を置かずに AWS IoT 証明書を払い出せる。
- Onyx が挿入され、SORACOM Air 回線が確立していること自体を認証境界にできる。
- Greengrass Core が必要とする X.509 証明書と秘密鍵を、その場で device ごとに作れる。

採用しなかったもの:

- SORACOM Endorse の SIM 認証: 今回の目的は AWS IoT / Greengrass 用 X.509 証明書の払い出しなので、Krypton の回線認証が目的に直結する。
- 事前生成した証明書の配布: SD カード image や repository に秘密鍵を混入させるリスクが高く、複数台展開で証明書重複も起きやすい。
- device 側 AWS credential による Greengrass installer provisioning: device にクラウド管理 credential を配る必要がある。

### 6. Thing name は原則 SORACOM group の `thingNamePattern` に任せる

ゼロタッチ運用では `KRYPTON_THING_NAME=""` を標準にし、Krypton request body で thing name を固定指定しません。SIM / IMSI を含む `thingNamePattern` を SORACOM group 側で設定します。

理由:

- 複数台が同じ MQTT clientId を使うと `SESSION_TAKEN_OVER` が発生する。
- device 側 payload を batch 共通にしやすく、個体ごとの設定ファイル差し替えを減らせる。
- SIM 単位の識別子を使うことで、Onyx / SIM を差し替えたときの所有境界が明確になる。

`KRYPTON_THING_NAME` は lab test や単発検証用の escape hatch とし、量産・配布では空にします。

### 7. Greengrass は manual provisioning にする

Greengrass Core は、Krypton が払い出した証明書を `/greengrass/v2` に配置し、`Greengrass.jar --init-config` で manual provisioning します。

理由:

- 証明書の出所を Krypton に統一できる。
- Greengrass installer に AWS credential を渡さなくてよい。
- 既存の AWS IoT Thing / certificate / policy / role alias と整合しやすい。

運用上の前提:

- AWS IoT policy には Greengrass Core と `iot:AssumeRoleWithCertificate` に必要な権限を含める。
- `GREENGRASS_ROLE_ALIAS`、`AWS_IOT_DATA_ENDPOINT`、`AWS_IOT_CRED_ENDPOINT` は `device.env` で渡す。
- Greengrass Nucleus zip は base image または payload に同梱できる。現地 first boot で download しない運用を優先する。

### 8. first boot は systemd timer で再試行する

`krgg-provision.service` と `krgg-provision.timer` で `/opt/krgg/firstboot-provision.sh` を再試行可能にしています。

理由:

- 起動直後は modem 認識、radio attach、NetworkManager の state 変化に時間がかかる。
- 現地では一時的な圏外や SIM session 遅延がありうる。
- `last-status` と log を残すことで、SSH できた後の原因切り分けがしやすい。
- SSH できない場合に備え、boot partition の `krgg/status/` にも `last-status`、status history、失敗時の診断 snapshot を残す。

成功時は `/var/lib/krgg/provisioned` を作り、timer を無効化します。これにより reboot 後に同じ provisioning を繰り返しません。

### 9. public repository では実環境値を持たない

`examples/device.env.example` は placeholder だけを置き、実際の endpoint や role alias は利用者が `device.env` として渡します。証明書や秘密鍵は `.gitignore` で除外しています。

理由:

- AWS / SORACOM の tenant 固有情報を repository に残さない。
- 同じ script を複数 account / group / region で使える。
- cloud-side setup と device-side setup の責務が分かれ、review 時に credential 混入を見つけやすい。

## 使い分け

### 手元検証や既に SSH できる Raspberry Pi

`scripts/setup-raspi.sh --env ./device.env` を使います。必要なら `--interface wwan1` で Krypton bootstrap に使う interface を固定します。

### 複数台配布や現地投入

`tools/prepare-base-image.sh` で依存入り base image を作り、`tools/inject-sd.sh` で boot partition に payload を注入します。first boot は `setup_eg25.sh`、Krypton、Greengrass の順に自己構成し、失敗時は timer で再試行します。

## 見直すべきタイミング

- 配布台数が増え、device ごとの状態管理や監査ログを中央集約したくなったとき。
- Onyx 以外の modem や APN を同じ repository で正式対応する必要が出たとき。
- Greengrass deployment まで含めて fleet 単位で自動化する必要が出たとき。
- `thingNamePattern` や policy を group ごとに分ける運用が増え、cloud-side setup をコード化したくなったとき。
