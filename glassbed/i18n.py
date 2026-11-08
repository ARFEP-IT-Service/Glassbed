"""Tiny translation helper.

Source strings are English. To add a language, add its code to LANGUAGES and a
table to TRANSLATIONS – missing entries fall back to English.
"""
from __future__ import annotations

import locale
import os

# code -> name in its own language (shown in the language switcher)
LANGUAGES = {"de": "Deutsch", "en": "English", "tr": "Türkçe"}

_DUPLEX_HINT = (
    "The front sides are printing.\n\nWhen they are done, take the stack from the output tray "
    "and put it back into the paper tray so the blank sides get printed (usually: do not flip it, "
    "just move it).\n\nTip: try it once with 4 pages.\n\nContinue with the back sides?"
)
_SCAN_HINT = "Place a document on the glass or in the feeder\nand click “Scan”."
_DROP_HINT = "Drop PDFs or images here\nor click “Add files…”."

TRANSLATIONS: dict[str, dict[str, str]] = {
    "de": {
        # header / device
        "Language": "Sprache",
        "Edit": "Bearbeiten",
        "Notification area": "Infobereich",
        "Show icon in the notification area": "Symbol im Infobereich anzeigen",
        "Start with Windows": "Mit Windows starten",
        "With the icon, closing the window keeps Glassbed running in the notification area; it can scan from there and warns when toner runs low.":
            "Mit dem Symbol läuft Glassbed beim Schließen des Fensters im Infobereich weiter; von dort kann gescannt werden, und es warnt, wenn der Toner zur Neige geht.",
        "This system has no notification area.": "Dieses System hat keinen Infobereich.",
        "Quick scan": "Schnell-Scan",
        "Quit": "Beenden",
        "Glassbed keeps running in the notification area.": "Glassbed läuft im Infobereich weiter.",
        "Toner low": "Toner fast leer",
        "{name}: {level} % left": "{name}: noch {level} %",
        "About": "Über",
        "Glassbed is an open-source project by {company}.": "Glassbed ist ein Open-Source-Projekt von {company}.",
        "IT service · Göttingen & nationwide": "IT-Service · Göttingen & bundesweit",
        "Get IT help": "IT-Hilfe anfragen",
        "Unsaved scans": "Ungespeicherte Scans",
        "{n} scanned page(s) have not been saved yet. If you close Glassbed now, they are lost.":
            "{n} gescannte Seite(n) sind noch nicht gespeichert. Wenn du Glassbed jetzt schließt, gehen sie verloren.",
        "A scan is still running. If you close Glassbed now, it is cancelled and the pages are lost.":
            "Ein Scan läuft noch. Wenn du Glassbed jetzt schließt, wird er abgebrochen und die Seiten gehen verloren.",
        "Save and close": "Speichern und schließen",
        "Close without saving": "Ohne Speichern schließen",
        "Tool": "Werkzeug",
        "Blur": "Unscharf",
        "Blur suits faces and photos. For numbers like an IBAN, black is safer.":
            "Unscharf passt für Gesichter und Fotos. Für Zahlen wie eine IBAN ist Schwarz sicherer.",
        "Fit": "Einpassen",
        "Zoom in": "Vergrößern",
        "Zoom out": "Verkleinern",
        "Mouse wheel: zoom · Space or right mouse button + drag: move":
            "Mausrad: zoomen · Leertaste oder rechte Maustaste + ziehen: verschieben",
        "Redact": "Schwärzen",
        "Black": "Schwarz",
        "White": "Weiß",
        "Remove all": "Alle entfernen",
        "Drag a box over what should disappear. Click a box to select it, Del removes it. It is burned into the saved file and cannot be undone there.":
            "Rechteck über das ziehen, was verschwinden soll. Rechteck anklicken und ziehen zum Verschieben, an den Griffpunkten zum Vergrößern, Pfeiltasten zum Feinjustieren, Entf zum Löschen. Im gespeicherten Dokument ist die Schwärzung fest eingebrannt.",
        "{n} redaction(s) on this page": "{n} Schwärzung(en) auf dieser Seite",
        "Back": "Zurück",
        "Print back sides": "Rückseiten drucken",
        "Edit page": "Seite bearbeiten",
        "Edited": "Bearbeitet",
        "Crop, straighten, brightness …": "Zuschneiden, begradigen, Helligkeit …",
        "Crop": "Zuschneiden",
        "Auto": "Automatisch",
        "Find the document on the scanner glass": "Dokument auf dem Scannerglas automatisch finden",
        "Whole page": "Ganze Seite",
        "Drag the frame or its handles. Double-click: whole page.":
            "Rahmen oder Griffpunkte ziehen. Doppelklick: ganze Seite.",
        "Rotate": "Drehen",
        "Straighten": "Begradigen",
        "Brightness": "Helligkeit",
        "Contrast": "Kontrast",
        "Double-click to reset": "Doppelklick zum Zurücksetzen",
        "Reset page": "Seite zurücksetzen",
        "Apply": "Übernehmen",
        "Settings": "Einstellungen",
        "Appearance": "Darstellung",
        "System": "System",
        "Light": "Hell",
        "Dark": "Dunkel",
        "Default save folder": "Standard-Speicherordner",
        "Scans are saved here unless you pick another folder in the scan tab.":
            "Scans werden hier gespeichert, außer du wählst im Scan-Tab einen anderen Ordner.",
        "Done": "Fertig",
        "Choose folder…": "Ordner wählen…",
        "Quality": "Qualität",
        "High": "Hoch",
        "Normal": "Normal",
        "Compact": "Kompakt",
        "Files": "Dateien",
        "One file": "Eine Datei",
        "Per page": "Je Seite",
        "Every N": "Je N Seiten",
        "pages per file": "Seiten pro Datei",
        "Copy": "Kopie",
        "Saving…": "Speichere…",
        "Saved": "Gespeichert",
        "Already saved": "Bereits gespeichert",
        "{n} files": "{n} Dateien",
        "Open": "Öffnen",
        "Show in folder": "Im Ordner zeigen",
        "Search": "Suchen",
        "Searching for devices…": "Suche Geräte im Netzwerk…",
        "No devices found. Enter the IP address manually.": "Keine Geräte gefunden. Bitte IP-Adresse eingeben.",
        "Found {n} device(s).": "{n} Gerät(e) gefunden.",
        "Open the printer's built-in web page": "Eingebaute Webseite des Druckers öffnen",
        "IP address or host name": "IP-Adresse oder Hostname",
        "Ready": "Bereit",
        "Busy": "Beschäftigt",
        "Stopped": "Angehalten",
        "Offline": "Nicht erreichbar",
        "Connecting…": "Verbinde…",
        "No printer selected.": "Kein Drucker ausgewählt.",
        "Scan": "Scannen",
        "Print": "Drucken",
        # scan tab
        "Source": "Quelle",
        "Glass": "Glas",
        "Feeder": "Einzug",
        "Mode": "Modus",
        "Color": "Farbe",
        "Gray": "Grau",
        "B/W": "S/W",
        "Resolution": "Auflösung",
        "Paper": "Papier",
        "Full area": "Ganze Fläche",
        "Content": "Inhalt",
        "Document": "Dokument",
        "Photo": "Foto",
        "Cancel": "Abbrechen",
        "Next scan is added to the current pages.": "Neue Scans werden an die vorhandenen Seiten angehängt.",
        "Rotate left": "Links drehen",
        "Rotate right": "Rechts drehen",
        "Delete": "Löschen",
        "Clear all": "Alle entfernen",
        _SCAN_HINT: "Lege ein Dokument auf das Glas oder in den Einzug\nund klicke auf „Scannen“.",
        "File name": "Dateiname",
        "Format": "Format",
        "Folder": "Ordner",
        "Choose folder": "Ordner wählen",
        "Save": "Speichern",
        "Copies": "Kopien",
        "Print copy": "Als Kopie drucken",
        "Clear pages after saving": "Seiten nach dem Speichern leeren",
        "Open folder after saving": "Ordner nach dem Speichern öffnen",
        "Scanning…": "Scanne…",
        "{n} page(s) scanned.": "{n} Seite(n) gescannt.",
        "Scan cancelled.": "Scan abgebrochen.",
        "Saved: {path}": "Gespeichert: {path}",
        "{n} page(s)": "{n} Seite(n)",
        "The document feeder is empty. Insert pages or use the glass.":
            "Der Vorlageneinzug ist leer. Lege Seiten ein oder nutze das Glas.",
        "The scanner is busy. Try again in a moment.": "Der Scanner ist beschäftigt. Versuch es gleich nochmal.",
        "Scan failed": "Scannen fehlgeschlagen",
        "Could not save": "Speichern fehlgeschlagen",
        # print tab
        "Add files…": "Dateien hinzufügen…",
        "Remove": "Entfernen",
        _DROP_HINT: "PDFs oder Bilder hierher ziehen\noder „Dateien hinzufügen…“ klicken.",
        "Pages": "Seiten",
        "All": "Alle",
        "e.g. 1-3, 5": "z. B. 1-3, 5",
        "Color mode": "Farbmodus",
        "Manual duplex": "Manueller Duplex",
        "Print both sides by reinserting the stack": "Beidseitig drucken durch Wiedereinlegen des Stapels",
        "Printing…": "Drucke…",
        "Preparing page {i} of {n}…": "Bereite Seite {i} von {n} vor…",
        "Sent to printer.": "An den Drucker gesendet.",
        "Print failed": "Drucken fehlgeschlagen",
        "Invalid page range.": "Ungültiger Seitenbereich.",
        "Nothing to print.": "Nichts zu drucken.",
        "Second side": "Rückseiten",
        _DUPLEX_HINT:
            "Die Vorderseiten werden gedruckt.\n\nWenn sie fertig sind, nimm den Stapel aus dem Ausgabefach "
            "und lege ihn wieder ins Papierfach, sodass die leeren Seiten bedruckt werden (meist: nicht "
            "umdrehen, einfach umlegen).\n\nTipp: Probier es einmal mit 4 Seiten aus.\n\nMit den Rückseiten fortfahren?",
        "Could not open file": "Datei konnte nicht geöffnet werden",
        "Supported files": "Unterstützte Dateien",
        "Loading pages…": "Lade Seiten…",
    },
    "tr": {
        # header / device
        "Language": "Dil",
        "Edit": "Düzenle",
        "Notification area": "Bildirim alanı",
        "Show icon in the notification area": "Simgeyi bildirim alanında göster",
        "Start with Windows": "Windows ile başlat",
        "With the icon, closing the window keeps Glassbed running in the notification area; it can scan from there and warns when toner runs low.":
            "Simge açıkken pencereyi kapatmak Glassbed'i bildirim alanında çalışır durumda tutar; oradan tarama yapılabilir ve toner azaldığında uyarır.",
        "This system has no notification area.": "Bu sistemde bildirim alanı yok.",
        "Quick scan": "Hızlı tarama",
        "Quit": "Çıkış",
        "Glassbed keeps running in the notification area.": "Glassbed bildirim alanında çalışmaya devam ediyor.",
        "Toner low": "Toner azaldı",
        "{name}: {level} % left": "{name}: %{level} kaldı",
        "About": "Hakkında",
        "Glassbed is an open-source project by {company}.": "Glassbed, {company} tarafından geliştirilen açık kaynaklı bir projedir.",
        "IT service · Göttingen & nationwide": "BT hizmeti · Göttingen ve tüm Almanya",
        "Get IT help": "BT desteği al",
        "Unsaved scans": "Kaydedilmemiş taramalar",
        "{n} scanned page(s) have not been saved yet. If you close Glassbed now, they are lost.":
            "{n} taranmış sayfa henüz kaydedilmedi. Glassbed'yi şimdi kapatırsanız kaybolur.",
        "A scan is still running. If you close Glassbed now, it is cancelled and the pages are lost.":
            "Bir tarama devam ediyor. Glassbed'yi şimdi kapatırsanız iptal edilir ve sayfalar kaybolur.",
        "Save and close": "Kaydet ve kapat",
        "Close without saving": "Kaydetmeden kapat",
        "Tool": "Araç",
        "Blur": "Bulanık",
        "Blur suits faces and photos. For numbers like an IBAN, black is safer.":
            "Bulanık, yüzler ve fotoğraflar için uygundur. IBAN gibi numaralar için siyah daha güvenlidir.",
        "Fit": "Sığdır",
        "Zoom in": "Yakınlaştır",
        "Zoom out": "Uzaklaştır",
        "Mouse wheel: zoom · Space or right mouse button + drag: move":
            "Fare tekerleği: yakınlaştır · Boşluk veya sağ fare tuşu + sürükle: kaydır",
        "Redact": "Karart",
        "Black": "Siyah",
        "White": "Beyaz",
        "Remove all": "Tümünü kaldır",
        "Drag a box over what should disappear. Click a box to select it, Del removes it. It is burned into the saved file and cannot be undone there.":
            "Gizlenecek alanın üzerine bir kutu çizin. Taşımak için kutuyu sürükleyin, boyutlandırmak için tutamaçları kullanın, ince ayar için ok tuşları, silmek için Del. Kaydedilen dosyada karartma kalıcıdır.",
        "{n} redaction(s) on this page": "Bu sayfada {n} karartma",
        "Back": "Geri",
        "Print back sides": "Arka yüzleri yazdır",
        "Edit page": "Sayfayı düzenle",
        "Edited": "Düzenlendi",
        "Crop, straighten, brightness …": "Kırp, düzelt, parlaklık …",
        "Crop": "Kırp",
        "Auto": "Otomatik",
        "Find the document on the scanner glass": "Tarayıcı camındaki belgeyi otomatik bul",
        "Whole page": "Tüm sayfa",
        "Drag the frame or its handles. Double-click: whole page.":
            "Çerçeveyi veya tutamaçları sürükleyin. Çift tıklama: tüm sayfa.",
        "Rotate": "Döndür",
        "Straighten": "Düzelt",
        "Brightness": "Parlaklık",
        "Contrast": "Kontrast",
        "Double-click to reset": "Sıfırlamak için çift tıklayın",
        "Reset page": "Sayfayı sıfırla",
        "Apply": "Uygula",
        "Settings": "Ayarlar",
        "Appearance": "Görünüm",
        "System": "Sistem",
        "Light": "Açık",
        "Dark": "Koyu",
        "Default save folder": "Varsayılan kayıt klasörü",
        "Scans are saved here unless you pick another folder in the scan tab.":
            "Tarama sekmesinde başka bir klasör seçmezseniz taramalar buraya kaydedilir.",
        "Done": "Tamam",
        "Choose folder…": "Klasör seç…",
        "Quality": "Kalite",
        "High": "Yüksek",
        "Normal": "Normal",
        "Compact": "Kompakt",
        "Files": "Dosyalar",
        "One file": "Tek dosya",
        "Per page": "Sayfa başı",
        "Every N": "Her N sayfa",
        "pages per file": "dosya başına sayfa",
        "Copy": "Kopya",
        "Saving…": "Kaydediliyor…",
        "Saved": "Kaydedildi",
        "Already saved": "Zaten kaydedildi",
        "{n} files": "{n} dosya",
        "Open": "Aç",
        "Show in folder": "Klasörde göster",
        "Search": "Ara",
        "Searching for devices…": "Ağdaki cihazlar aranıyor…",
        "No devices found. Enter the IP address manually.": "Cihaz bulunamadı. IP adresini elle girin.",
        "Found {n} device(s).": "{n} cihaz bulundu.",
        "Open the printer's built-in web page": "Yazıcının web arayüzünü aç",
        "IP address or host name": "IP adresi veya ana bilgisayar adı",
        "Ready": "Hazır",
        "Busy": "Meşgul",
        "Stopped": "Durduruldu",
        "Offline": "Erişilemiyor",
        "Connecting…": "Bağlanıyor…",
        "No printer selected.": "Yazıcı seçilmedi.",
        "Scan": "Tara",
        "Print": "Yazdır",
        # scan tab
        "Source": "Kaynak",
        "Glass": "Cam",
        "Feeder": "Besleyici",
        "Mode": "Mod",
        "Color": "Renkli",
        "Gray": "Gri",
        "B/W": "S/B",
        "Resolution": "Çözünürlük",
        "Paper": "Kâğıt",
        "Full area": "Tüm alan",
        "Content": "İçerik",
        "Document": "Belge",
        "Photo": "Fotoğraf",
        "Cancel": "İptal",
        "Next scan is added to the current pages.": "Yeni taramalar mevcut sayfalara eklenir.",
        "Rotate left": "Sola döndür",
        "Rotate right": "Sağa döndür",
        "Delete": "Sil",
        "Clear all": "Tümünü kaldır",
        _SCAN_HINT: "Belgeyi cama veya besleyiciye yerleştirin\nve “Tara”ya tıklayın.",
        "File name": "Dosya adı",
        "Format": "Biçim",
        "Folder": "Klasör",
        "Choose folder": "Klasör seç",
        "Save": "Kaydet",
        "Copies": "Kopya",
        "Print copy": "Kopya yazdır",
        "Clear pages after saving": "Kaydettikten sonra sayfaları temizle",
        "Open folder after saving": "Kaydettikten sonra klasörü aç",
        "Scanning…": "Taranıyor…",
        "{n} page(s) scanned.": "{n} sayfa tarandı.",
        "Scan cancelled.": "Tarama iptal edildi.",
        "Saved: {path}": "Kaydedildi: {path}",
        "{n} page(s)": "{n} sayfa",
        "The document feeder is empty. Insert pages or use the glass.":
            "Belge besleyici boş. Sayfa yerleştirin veya camı kullanın.",
        "The scanner is busy. Try again in a moment.": "Tarayıcı meşgul. Birazdan tekrar deneyin.",
        "Scan failed": "Tarama başarısız",
        "Could not save": "Kaydedilemedi",
        # print tab
        "Add files…": "Dosya ekle…",
        "Remove": "Kaldır",
        _DROP_HINT: "PDF veya resimleri buraya sürükleyin\nya da “Dosya ekle…”ye tıklayın.",
        "Pages": "Sayfalar",
        "All": "Tümü",
        "e.g. 1-3, 5": "örn. 1-3, 5",
        "Color mode": "Renk modu",
        "Manual duplex": "Elle çift taraflı",
        "Print both sides by reinserting the stack": "Kâğıt destesini yeniden yerleştirerek iki yüze yazdır",
        "Printing…": "Yazdırılıyor…",
        "Preparing page {i} of {n}…": "Sayfa {i}/{n} hazırlanıyor…",
        "Sent to printer.": "Yazıcıya gönderildi.",
        "Print failed": "Yazdırma başarısız",
        "Invalid page range.": "Geçersiz sayfa aralığı.",
        "Nothing to print.": "Yazdırılacak bir şey yok.",
        "Second side": "Arka yüzler",
        _DUPLEX_HINT:
            "Ön yüzler yazdırılıyor.\n\nBittiğinde desteyi çıkış tepsisinden alın ve boş yüzler "
            "yazdırılacak şekilde kâğıt tepsisine geri koyun (genellikle: çevirmeden, olduğu gibi "
            "taşıyın).\n\nİpucu: Bir kez 4 sayfayla deneyin.\n\nArka yüzlerle devam edilsin mi?",
        "Could not open file": "Dosya açılamadı",
        "Supported files": "Desteklenen dosyalar",
        "Loading pages…": "Sayfalar yükleniyor…",
    },
}


def _system_language() -> str:
    try:
        from PySide6.QtCore import QLocale
        code = QLocale.system().name()[:2].lower()
    except Exception:
        code = (locale.getlocale()[0] or "en")[:2].lower()
    return code if code in LANGUAGES else "en"


def _initial_language() -> str:
    env = os.environ.get("GLASSBED_LANG", "")[:2].lower()
    if env in LANGUAGES:
        return env
    try:
        from . import config
        saved = config.settings().value("ui/language", "")
        if saved in LANGUAGES:
            return saved
    except Exception:
        pass
    return _system_language()


LANG = _initial_language()


def set_language(code: str) -> None:
    global LANG
    if code in LANGUAGES:
        LANG = code


def tr(text: str, **kwargs) -> str:
    out = TRANSLATIONS.get(LANG, {}).get(text, text)
    return out.format(**kwargs) if kwargs else out
