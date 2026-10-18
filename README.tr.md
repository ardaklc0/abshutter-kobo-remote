# Kobo + AB Shutter 3: Bluetooth sayfa çevirici

> 🇬🇧 English: [README.md](README.md)

Ucuz bir Bluetooth kamera deklanşörünü (**AB Shutter 3**) Kobo e-okuyucuda sayfa çevirme kumandasına dönüştürür. Hem Kobo'nun kendi okuyucusunda (Nickel) hem de **KOReader**'da çalışır.

- **Kısa basış:** sonraki sayfa
- **Uzun basış** (yarım saniyeden uzun): önceki sayfa. Bırakmayı beklemeden çevirir.

Ek olarak, KOReader kullanırken sık yaşanan iki sorunu da düzeltir:

- KOReader'dan çıkınca **NickelMenu'nün kaybolması**
- Kobo yazılımı güncellendikten sonra **KFMon'un açılışta başlamaması** (`kfmon: error checking '/tmp/kfmon-ipc.ctl'`)

> ⚠️ Bu proje Kobo'nun sistem dosyalarından birini (`/etc/init.d/on-animator.sh`) değiştirir ve root yetkisiyle çalışan betikler kurar. Kendi sorumluluğunuzda kullanın. Kobo veya KOReader ile bir bağlantısı yoktur.

---

## Test edilen cihazlar

| Cihaz | Kobo FW | KOReader | Bluetooth yığını | Nickel | KOReader |
|---|---|---|---|---|---|
| Kobo Clara Colour (BW de aynı aile) | 4.46 | v2026.03 | MediaTek (`mtkbtd`) | ✅ | ✅ |
| Kobo Sage | 4.38 | v2026.07.2 | BlueZ (`bluetoothd`, Broadcom) | ✅ | ✅ |

Başka Bluetooth'lu Kobo'larda (Libra 2, Libra Colour, Elipsa 2E, Clara 2E) da çalışması muhtemel. Ancak Sage'e özgü bazı değerlerin (ör. `hciattach` parametreleri) uyarlanması gerekebilir. Ayrıntılar aşağıda.

---

## Nasıl çalışıyor?

### 1. Shutter ne gönderiyor?

AB Shutter 3'ün iki tuşu da (CAMERA 360 / iOS ve ANDROID) **donanım seviyesinde aynı sinyali** gönderir: `KEY_VOLUMEUP` (kod 115). HID tanımlayıcısında yalnızca bir consumer-control raporu var: Ses Açma, Ses Kısma, Sessiz, Güç. Klavye (Enter) raporu yok, bu yüzden iki tuşu birbirinden ayırmak mümkün değil. Yön bu nedenle **basma süresiyle** belirleniyor.

Kobo bu tuşu sayfa çevirme olarak tanımıyor. Shutter Bluetooth'tan bağlansa da hiçbir şey olmamasının sebebi bu.

### 2. Yeniden eşleme programı (`shutter_remap.lua`)

KOReader'ın içinde gelen LuaJIT ile çalışan küçük bir program:

1. `/proc/bus/input/devices` içinde `AB Shutter3` adlı aygıtı bulur ve onu `EVIOCGRAB` ile kendine alır.
2. `/dev/uinput` üzerinden **"Shutter Remap"** adında sanal bir klavye oluşturur.
3. Basış süresine göre sanal klavyeden tuş gönderir:
   - **Nickel açıksa:** `KEY_RIGHT` / `KEY_LEFT`. Nickel Bluetooth klavyelerin ok tuşlarıyla sayfa çeviriyor; `KEY_PAGEDOWN` ise işe yaramadı.
   - **KOReader açıksa:** `KEY_F24` (194) / `KEY_F23` (193). Bunlar Kobo'nun fiziksel sayfa tuşlarının kodları. KOReader'ın aygıt taraması (FBInk) sanal aygıtı bu yüzden `PAGINATION_BUTTONS` olarak tanıyıp kendiliğinden açıyor.
4. Shutter bağlantısı koparsa 3 saniyede bir yeniden arar. Kobo uyuyup uyandığında da kendini toparlar.

`/tmp/shutter_remap.paused` dosyası varsa tuşları yok sayar; KOReader eklentisi duraklatmayı bununla yapıyor. Program bu durumda kapanmaz, böylece KOReader'ın açık tuttuğu sanal aygıt kaybolmaz.

### 3. KOReader eklentisi (`shutter.koplugin`)

**Ağ (Network) → Bluetooth & Shutter** menüsünü ekler:

- **Bluetooth:** aç/kapat
- **Shutter: connected / not connected:** dokununca bağlanır
- **Turn pages with shutter:** yeniden eşlemeyi açar/duraklatır
- **Auto-connect on start and wake:** varsayılan olarak açık

KOReader açılırken Nickel'i kapatır, Sage gibi cihazlarda Bluetooth'u da kapatır. Eklenti Bluetooth'u Nickel olmadan yönetir:

- **MediaTek cihazlar (Clara BW/Colour):** Kobo'nun `mtkbtd` servisi KOReader açıkken de çalışmaya devam ediyor. Eklenti D-Bus üzerinden (`com.kobo.mtk.bluedroid`, BlueZ uyumlu `org.bluez.Adapter1`/`Device1` arayüzü) adaptörü açıp kapatıyor ve shutter'ı bağlıyor.
- **BlueZ cihazlar (Sage):** `koreader.sh` açılışta çipin gücünü kesiyor (`rfkill` + `ntx_io 126 0`) ve `bluetoothd`'yi kapatıyor. Nickel'in başlattığı `hciattach` ise çalışmaya devam ediyor, yani `hci0` var görünse de çip kapalı oluyor. Eklenti şu sırayı izliyor:
  1. Eski `hciattach`'ı kapatır.
  2. Çipe güç verir (`ntx_io 126 1`, `rfkill`=1).
  3. `hciattach`'ı yeniden başlatır.
  4. `bluetoothd`'yi arka planda çalıştırır.
  5. Adaptörü açıp shutter'ı bağlar.

  Bu sıra `bluez_up.sh` betiğinde. `hciattach` yeniden başlatıldıktan sonra çip komutlara cevap veriyor ama sıfırlanana kadar (`hciconfig hci0 reset`) düşük enerjili tarama yapamıyor. Betik bu yüzden çipi sıfırlıyor; sıfırlamadan shutter hiç görünmüyor. Aynı çip Wi-Fi'ı da yönetiyor ve KOReader çoğu zaman tam o sırada Wi-Fi'ı açıyor. Betik bu yüzden çipin gücünü uzun beklemelerle kapatıp açıyor ve en fazla 3 kez yeniden deniyor. Bir kilit, eklentinin iki kopyasının (dosya yöneticisi ve okuyucu) çipe aynı anda dokunmasını önlüyor.

  Eşleşme bilgileri kalıcı olarak `/var/db/bluetooth` altında durduğu için yeniden eşleştirme gerekmiyor.

**Otomatik bağlanma** açıkken her şey kendiliğinden olur:

- **Açılışta ve uyanınca** eklenti Bluetooth'u kurar. Uyku `hciattach`'ı öldürebildiği için uyanışta bağlantı her zaman baştan kurulur. Shutter yaklaşık 15 saniyede bağlanır ve ekranda "Shutter connected" bildirimi çıkar.
- **Bekçi**, dakikada bir kontrol eder ve Bluetooth kapalıysa, örneğin bir kurulum başarısız olduysa, yeniden kurar. Menüden Bluetooth'u kapatırsan, tekrar açana kadar devreye girmez.
- Her kurulum nedeniyle birlikte (`start`, `resume`, `watchdog`, `menu`) `/tmp/shutter_bt.log` dosyasına yazılır.

KOReader aygıtları yalnızca açılışta tarıyor. Program KOReader'dan sonra başlarsa eklenti sanal aygıtı `Device.input:open()` ile kendisi açıyor.

### 4. KOReader yaması: yalnızca tuşsuz cihazlar (`2-shutter-pagekeys.lua`)

KOReader, Clara gibi fiziksel sayfa tuşu olmayan cihazlarda (`hasKeys = no`) sayfa tuşu işleyicilerini hiç kaydetmiyor. Bu kullanıcı yaması `Device.hasKeys`'i `true` yapıyor. Sage gibi tuşlu cihazlarda **gerekmez**.

### 5. Açılış betiği düzeltmeleri (`on-animator.sh`)

KFMon, `/etc/init.d/on-animator.sh` dosyasını kendi sürümüyle değiştirerek açılışta başlıyor. Bu dosya hem Kobo açılırken hem de KOReader'dan çıkışta `nickel.sh` tarafından çalıştırılıyor. Başına iki blok ekleniyor:

- **NickelMenu düzeltmesi.** NickelMenu yüklenirken kendi dosyasını geçici olarak `libnm.so.failsafe` adıyla değiştiriyor ve Nickel düzgün açılırsa yaklaşık 20 saniye sonra eski adına döndürüyor. KOReader bu süre dolmadan başlatılırsa (KOReader Nickel'i kapatır) dosya `.failsafe` adında kalıyor ve **NickelMenu bir sonraki açılışta görünmüyor**. Eklenen blok, Nickel başlamadan önce takılı kalan dosyayı geri çeviriyor.
- **Shutter programını otomatik başlatma.** Program zaten çalışıyorsa ikinci bir kopya açmıyor.

> Bu düzeltme, NickelMenu'nün güvenlik mekanizmasını büyük ölçüde devre dışı bırakır. NickelMenu bir gün gerçekten çökmeye yol açarsa artık kendini kapatamaz. Böyle bir durumda `libnm.so`'yu SSH ile silin, ya da `.adds/nm/uninstall` dosyasını oluşturun.

**Kobo yazılım güncellemesi** `on-animator.sh`'ı orijinaline döndürebilir. KFMon'un açılmaması bunun belirtisi. O durumda KFMon'u yeniden kurun (KOReader/KFMon `KoboRoot.tgz`) ve başlık bloğunu tekrar ekleyin.

---

## Dosyalar

```
onboard/                                    → Kobo'nun USB depolama alanı (/mnt/onboard)
  .adds/shutter/shutter_remap.lua           Yeniden eşleme programı
  .adds/nm/shutter                          NickelMenu girişleri (Start/Stop shutter, Start/Stop SSH)
  .adds/koreader/plugins/shutter.koplugin/  KOReader eklentisi (bluez_up.sh: BlueZ kurulumu)
  .adds/koreader/patches/2-shutter-pagekeys.lua   Yalnızca tuşsuz cihazlar (Clara) için
rootfs/
  etc/init.d/on-animator-head.sh            /etc/init.d/on-animator.sh'ın başına eklenecek blok
```

---

## Kurulum

### Gerekenler

- Bluetooth'lu bir Kobo
- [KOReader](https://github.com/koreader/koreader), [NickelMenu](https://pgaskin.net/NickelMenu/) ve [KFMon](https://github.com/NiLuJe/kfmon). Genellikle KOReader'ın tek tıkla kurulum paketiyle birlikte gelirler.
- Kobo'da root shell. KOReader'ın SSH sunucusu yeterli (port 2222).

### 1. USB üzerinden kopyalanacaklar

Kobo'yu USB ile bağlayın ve `onboard/` altındaki her şeyi Kobo'nun köküne kopyalayın. Gizli `.adds` klasörü dahil.

- **Tuşsuz cihazlarda** (Clara): `patches/2-shutter-pagekeys.lua` kalsın.
- **Tuşlu cihazlarda** (Sage, Libra, Forma, Elipsa): bu dosyayı silin.

Windows'ta satır sonlarının LF kalmasına dikkat edin. NickelMenu ve `sh` CRLF ile sorun çıkarabilir.

### 2. SSH ile sistem tarafı

```sh
f=/etc/init.d/on-animator.sh
grep -q 'NM_LIB=' "$f" && echo "zaten kurulu" || {
  cp -p "$f" /usr/local/kfmon/on-animator.sh.kfmon            # yedek
  { echo '#!/bin/sh'; cat /mnt/onboard/on-animator-head.sh; tail -n +2 /usr/local/kfmon/on-animator.sh.kfmon; } > "$f"
  chmod 755 "$f"; sh -n "$f" && sync
}
```

`on-animator-head.sh`'ı önce `/mnt/onboard/` altına kopyalayın. İşiniz bitince silebilirsiniz.

### 3. Eşleştirme

1. Kobo'nun kendi menüsünden Bluetooth'u açın.
2. Shutter'ın açma düğmesini ışık yanıp sönene kadar basılı tutun.
3. Listede "AB Shutter3" görünce eşleştirin.

Eşleştirme bir kez yapılır.

### 4. Kullanım

- **Nickel:** program açılışta kendiliğinden başlar. Gerekirse NickelMenu → **Start shutter / Stop shutter**.
- **KOReader:** **Ağ (Network) → Bluetooth & Shutter**. Otomatik bağlanma açıksa KOReader açılınca Bluetooth açılır ve shutter bağlanır, 10-15 saniye sürebilir. Bağlanmazsa shutter'ın tuşuna bir kez basın.

---

## Bilinen sorunlar ve notlar

- **Nickel'de Bluetooth:** Kobo uyuyunca Bluetooth kapanır. Uyandıktan sonra Bluetooth'u tekrar açın, shutter kendiliğinden bağlanır.
- **Yeni sanal aygıtın ilk tuşu:** Nickel, yeni oluşan sanal klavyeden gelen ilk tuşu kaçırabiliyor. Program aygıtı bir kez oluşturup açık tuttuğu için pratikte sorun olmuyor.
- **Ekran klavyesi (doğrulanmadı):** Nickel sanal klavyeyi fiziksel klavye sanıp ekran klavyesini gizleyebilir. Böyle bir şey olursa NickelMenu → **Stop shutter**.
- **Sage değerleri:** `hciattach` parametreleri (`/dev/ttyS1 bcm43xx 1500000 ...`) Sage'de Nickel'in çalıştırdığı süreçten alındı. Başka sunxi cihazlarda Nickel açıkken `ps | grep hciattach` ile kontrol edip `main.lua` içindeki `BLUEZ.hciattach`'ı güncelleyin.
- **KOReader SSH güvenliği:** KOReader'da "şifresiz girişe izin ver" açıksa aynı ağdaki herkes root olarak girebilir. Anahtar kullanın ve **Login with key only** seçeneğini açın.
- **KOReader'dan çıkış:** KFMon'un `koreader.ini` dosyasında `reboot_on_exit=false` yoksa KOReader çıkışta Kobo'yu yeniden başlatır. Bu kurulumla ikisi de sorunsuz.

---

## Kaldırma

1. KOReader'da **Turn pages with shutter** seçeneğini kapatın ya da NickelMenu → **Stop shutter**.
2. Şu dosyaları silin:
   - `.adds/shutter/`
   - `.adds/nm/shutter`
   - `.adds/koreader/plugins/shutter.koplugin/`
   - `.adds/koreader/patches/2-shutter-pagekeys.lua`
3. SSH ile açılış betiğini geri yükleyin:
   ```sh
   cp -p /usr/local/kfmon/on-animator.sh.kfmon /etc/init.d/on-animator.sh && sync
   ```

---

## Bu proje nasıl ortaya çıktı?

Proje, [Claude Code](https://claude.com/claude-code) ile adım adım tersine mühendislik yapılarak geliştirildi:

1. Shutter'ın gönderdiği olaylar `/dev/input` üzerinden okundu ve HID tanımlayıcısı incelendi.
2. D-Bus trafiği dinlendi.
3. Nickel ve KOReader'ın hangi tuş kodlarını kabul ettiği deneme yoluyla bulundu.
4. Bluetooth yığınları cihaz üzerinde keşfedildi.

Aynı kurulumu başka bir cihaza bir yapay zekâ ajanıyla uyarlamak için [`PROMPT.tr.md`](PROMPT.tr.md) dosyasına bakın.

## Lisans

[AGPL-3.0](LICENSE), KOReader ile aynı lisans.
