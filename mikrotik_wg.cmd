@echo off
setlocal enabledelayedexpansion

:: Parametry
set "router_PUB=14hI8Xqllr1qfvom0Ws2yHWOjuaSvGkKzgySiLySaKQ="
set "endpoint=mohelnice.net:1111"
set "subnet=192.168.198"
set "allowedips=192.168.1.0/24"
set "dns=1.0.0.1, 8.8.8.8"
set "startip=5"
set "peerCount=2"

:: Přesun do dočasné složky
cd /D "%TEMP%"

:: Generuj konfiguraci pro každý peer
for /L %%n in (0,1,%peerCount%) do (
    set /a ipOffset=!startip!+%%n

    for /f "delims=" %%i in ('"c:\Program Files\WireGuard\wg.exe" genpsk') do set "PSK=%%i"
    for /f "delims=" %%i in ('"c:\Program Files\WireGuard\wg.exe" genkey') do set "PRIV=%%i"

    :: Zápis privátního klíče bez nového řádku
    echo|set /p=!PRIV!>privkey.txt

    for /f "delims=" %%i in ('cmd /c ""c:\Program Files\WireGuard\wg.exe" pubkey < privkey.txt"') do set "PUB=%%i"
    del privkey.txt

    set "configFile=peer-!ipOffset!-!PUB:~0,5!.conf"

    (
        echo [Interface]
        echo PrivateKey = !PRIV!
        echo Address = %subnet%.!ipOffset!/32
        echo DNS = %dns%
        echo.
        echo [Peer]
        echo PublicKey = %router_PUB%
        echo PresharedKey = !PSK!
        echo Endpoint = %endpoint%
        echo AllowedIPs = %allowedips%
        echo PersistentKeepalive = 25
    ) > "!configFile!"

    set "configrsc=peer-!ipOffset!-!PUB:~0,5!.rsc"
    set "peerName=peer!ipOffset!_!PUB:~0,5!"

    (
        echo /interface wireguard peers add \
        echo allowed-address=%subnet%.!ipOffset!/24,%allowedips% \
        echo interface=wireguard1 \
        echo name=!peerName! \
        echo preshared-key="!PSK!" \
        echo public-key="!PUB!"
    ) > "!configrsc!"

    echo ✅ Vytvořen: !configFile!
)

echo Hotovo. Konfigurace peerů jsou v %TEMP%.
