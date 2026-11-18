# Installing Thousand Realms

The easiest route on every system is the [itch app](https://itch.io/app), once the game is listed there. For direct downloads, use the file for your system from the [latest release](https://github.com/semdin/realm/releases/latest). The launcher then downloads the game and keeps itself and the game up to date.

## Windows

1. Download `ThousandRealms-Setup.exe` and open it. It needs no administrator rights.
2. Windows may show "Windows protected your PC", because the game is new and not code-signed yet. If you downloaded the file from the link above, choose **More info**, then **Run anyway**. Please leave SmartScreen and your antivirus switched on.
3. Choose whether you want a desktop shortcut. The launcher starts when setup finishes.

To uninstall, use **Settings > Apps > Installed apps > Thousand Realms**. It asks whether to delete the downloaded game too.

Prefer no installer? `ThousandRealms_Launcher.exe` is the same launcher as a single file.

## Linux

1. Download `ThousandRealms-linux-x86_64.tar.gz` and extract it in your home folder.
2. Double-click `ThousandRealms_Launcher`. If your file manager only opens it as a file, double-click `Thousand Realms.desktop` and choose to trust it.
3. The launcher adds itself to your application menu.

`ThousandRealms_Launcher-x86_64.AppImage` is the same launcher as one file and does not need FUSE. A browser download is not executable yet, so first open its **Properties > Permissions** and allow running it as a program.

The launcher needs glibc 2.35 or newer (Ubuntu 22.04, Debian 12, Fedora, Arch, SteamOS) and `curl`.

## macOS (macOS 11 or newer; the steps below are for macOS 15 or newer)

The launcher is not notarized by Apple yet, so macOS blocks the first start. You allow it once in System Settings. You do not need Terminal, and you do not need to turn any security feature off.

1. Download `ThousandRealms.dmg`, open it and drag **Thousand Realms Launcher** onto **Applications**.
2. Open your Applications folder and double-click **Thousand Realms Launcher**. macOS says it could not verify the app. Click **Done**, not Move to Trash.
3. Open **System Settings > Privacy & Security** and scroll down to **Security**. Next to the message about Thousand Realms Launcher, click **Open Anyway**. The button stays for about an hour after step 2.
4. Confirm with your password or Touch ID, then click **Open Anyway** once more.

If macOS says the app is damaged, or **Open Anyway** does not appear, please do not use Terminal commands or turn off macOS security. [Tell us](https://github.com/semdin/realm/issues) instead.

## Check your download

`SHA256SUMS-downloads.txt` in the release lists the SHA-256 of every download.

## Help

[Open an issue](https://github.com/semdin/realm/issues). The launcher's **Support** and **Logs** links take you there and to your log files.

---

# Thousand Realms kurulumu

Oyun listelendiğinde her sistemde en kolay yol [itch uygulamasıdır](https://itch.io/app). Doğrudan indirmek için [son sürümden](https://github.com/semdin/realm/releases/latest) sistemine uygun dosyayı al. Launcher oyunu indirir, kendini ve oyunu güncel tutar.

## Windows

1. `ThousandRealms-Setup.exe` dosyasını indirip aç. Yönetici izni gerekmez.
2. Oyun yeni olduğu ve henüz kod imzası taşımadığı için Windows "Windows bilgisayarınızı korudu" diyebilir. Dosyayı yukarıdaki bağlantıdan indirdiysen **Ek bilgi**, ardından **Yine de çalıştır** seçeneğini kullan. SmartScreen ve antivirüsünü lütfen açık bırak.
3. Masaüstü kısayolu isteyip istemediğini seç. Kurulum bitince launcher açılır.

Kaldırmak için **Ayarlar > Uygulamalar > Yüklü uygulamalar > Thousand Realms** yolunu izle. İndirilen oyunun da silinip silinmeyeceğini sorar.

Kurulum istemiyor musun? `ThousandRealms_Launcher.exe` aynı launcher'ın tek dosyalık hâlidir.

## Linux

1. `ThousandRealms-linux-x86_64.tar.gz` dosyasını indirip ev klasörüne çıkar.
2. `ThousandRealms_Launcher` dosyasına çift tıkla. Dosya yöneticin onu yalnızca dosya olarak açıyorsa `Thousand Realms.desktop` dosyasına çift tıklayıp güvendiğini onayla.
3. Launcher kendini uygulama menüsüne ekler.

`ThousandRealms_Launcher-x86_64.AppImage` aynı launcher'ın tek dosyalık hâlidir ve FUSE gerektirmez. Tarayıcıyla indirilen dosya henüz çalıştırılabilir değildir; önce **Özellikler > İzinler** bölümünden program olarak çalıştırılmasına izin ver.

Launcher, glibc 2.35 veya daha yenisini (Ubuntu 22.04, Debian 12, Fedora, Arch, SteamOS) ve `curl` paketini ister.

## macOS (macOS 11 veya daha yenisi; aşağıdaki adımlar macOS 15 ve sonrası içindir)

Launcher henüz Apple tarafından onaylanmadı (notarize edilmedi), bu yüzden macOS ilk açılışı engeller. Sistem Ayarları'ndan bir kez izin verirsin. Terminal gerekmez, hiçbir güvenlik özelliğini kapatman da gerekmez.

1. `ThousandRealms.dmg` dosyasını indirip aç, **Thousand Realms Launcher**'ı **Applications** (Uygulamalar) simgesinin üzerine sürükle.
2. Uygulamalar klasörünü aç ve **Thousand Realms Launcher**'a çift tıkla. macOS uygulamayı doğrulayamadığını söyler. **Bitti**'ye bas, Çöp Sepetine Taşı'ya değil.
3. **Sistem Ayarları > Gizlilik ve Güvenlik**'i aç, **Güvenlik** bölümüne in. Thousand Realms Launcher ile ilgili iletinin yanındaki **Yine de Aç**'a bas. Düğme 2. adımdan sonra yaklaşık bir saat görünür.
4. Parolan veya Touch ID ile onayla, ardından bir kez daha **Yine de Aç**'a bas.

macOS uygulamanın hasarlı olduğunu söylerse ya da **Yine de Aç** görünmezse lütfen Terminal komutları kullanma ve macOS güvenliğini kapatma. [Bize yaz](https://github.com/semdin/realm/issues).

## İndirdiğin dosyayı doğrula

Sürümdeki `SHA256SUMS-downloads.txt` her indirmenin SHA-256 değerini listeler.

## Yardım

[Bir kayıt aç](https://github.com/semdin/realm/issues). Launcher'daki **Destek** ve **Kayıtlar** bağlantıları seni oraya ve günlük dosyalarına götürür.
