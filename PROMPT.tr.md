# Yapay zekâ ajanı için kurulum/uyarlama istemi

> 🇬🇧 English: [PROMPT.md](PROMPT.md)

Aşağıdaki metni Claude Code gibi, terminal ve dosya erişimi olan bir ajana verin. Ajanı bu deponun klasöründe çalıştırın. Kobo'nun USB ile bağlı olması ya da aynı ağda SSH erişimi olması gerekir.

---

```
Bu depo, AB Shutter 3 Bluetooth deklanşörünü Kobo e-okuyucuda sayfa çevirme
kumandası yapan bir kurulum içeriyor (README.md'yi baştan sona oku). Görevin bunu
benim Kobo'ma kurmak ve gerekirse cihazıma uyarlamak.

Cihazım: <MODEL, örn. Kobo Libra 2>. Bluetooth'u var. KOReader, NickelMenu ve
KFMon kurulu (değilse önce bana söyle).

Adımlar:

1. Cihazı tanı.
   - USB bağlıysa .kobo/version dosyasından modeli ve yazılım sürümünü oku.
   - SSH için KOReader'ın SSH sunucusunu kullan (port 2222). PC'de yeni bir
     ed25519 anahtarı oluştur ve .adds/koreader/settings/SSH/authorized_keys
     dosyasına ekle. Şifresiz girişe güvenme.
   - Nickel açıkken (KOReader'da değil) şunları incele:
     * /proc/bus/input/devices
     * Bluetooth yığını: ps'te mtkbtd/btservice mi, bluetoothd/hciattach mı var?
     * D-Bus isimleri (org.bluez mi, com.kobo.mtk.bluedroid mi?)
     * /sys/devices/platform/bt/rfkill
     * hciattach'ın tam komut satırı
     * /etc/init.d/on-animator.sh'ın KFMon sürümü olup olmadığı
       (KFMon log'u: /usr/local/kfmon/kfmon.log)

2. Shutter'ı doğrula. Shutter'ı Nickel'den eşleştirmemi iste, ardından
   /dev/input/eventN'den ham olayları okuyarak tuşların gerçekten KEY_VOLUMEUP
   (115) gönderdiğini doğrula. KOReader'ın luajit'i ile FFI kullanabilirsin.
   Farklı bir kod geliyorsa shutter_remap.lua'yı uyarla.

3. Dosyaları kur. onboard/ içeriğini /mnt/onboard'a kopyala (satır sonları LF
   olmalı).
   - Cihazın fiziksel sayfa tuşları varsa patches/2-shutter-pagekeys.lua'yı
     KURMA.
   - Bunu anlamak için KOReader'ın frontend/device/kobo/device.lua dosyasında
     modelin hasKeys değerine bak.

4. Sistem tarafı. Önce /etc/init.d/on-animator.sh'ı yedekle. Sonra
   rootfs/etc/init.d/on-animator-head.sh bloğunu dosyanın başına (shebang'den
   sonra) ekle ve `sh -n` ile kontrol et. Bu adımdan önce ne yapacağını bana
   söyle ve onay al.

5. Bluetooth arka ucunu uyarla.
   - MediaTek ise MTK arka ucu olduğu gibi çalışmalı.
   - BlueZ ise main.lua'daki BLUEZ.hciattach değerini cihazdaki gerçek komut
     satırıyla değiştir.
   - KOReader açıkken (koreader.sh Bluetooth'u kapattıktan sonra) eklentinin
     açma sırasını önce elle, SSH üzerinden dene: çip gücü/rfkill, hciattach,
     bluetoothd (arka planda!), Adapter1.Powered, Device1.Connect. Çalışan sırayı
     eklentiye yansıt.

6. Test. Benden şunları iste ve sonuçları doğrula:
   - Nickel'de kısa ve uzun basış
   - KOReader'da kısa ve uzun basış
   - KOReader menüsünden Bluetooth kapat/aç ve yeniden bağlanma
   - KOReader'dan çıkış ve NickelMenu'nün yerinde kalması

Kurallar:
- Kobo'nun sistem dosyalarını değiştirmeden önce yedek al ve bana sor.
- Yalnızca bu iş için gerekenleri değiştir. KOReader'ın kendi dosyalarını
  (koreader.sh, frontend/) düzenleme; güncellemelerde silinirler. Bunun yerine
  eklenti ve kullanıcı yaması (patches/) kullan.
- Bir şey çalışmazsa tahmin etme; log'lara bak:
  /tmp/shutter_remap.log, .adds/koreader/crash.log, logread, dmesg.
- Bittiğinde neyi değiştirdiğini, yedeklerin nerede olduğunu ve neyi
  doğrulayamadığını özetle.
```
