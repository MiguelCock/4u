# Front_Collection

Permisions are added to android/app/src/main/AndroidManifest.xml

## How to connect the cellphone to the pc with adb

Enable ***Developer Options*** on your phone:
- Go to settings and scroll until the end.
- In ***about phone*** search your ***Build Number***.
- Tap it until prompted to activate dev settings.

### To connect through cable:
- Go to **Developer Options** → ***USB debugging*** and turn it on.

### To connect wireless:
- Make sure your phone and PC are on the same Wi-Fi network.
- Go to **Developer Options** → ***Wireless debugging*** and turn it on.
- Access Wireless debugging by tapping it.
- On your phone, tap Pair device with pairing code.
- On your PC, run:
```bash
adb pair IP_ADDRESS:PAIRING_PORT PAIR_CODE
```
- Then connect:
```bash
adb connect IP_ADDRESS:ADB_PORT
```

Verify:
```bash
adb devices
```

## To run the app

```bash
flutter run
```
