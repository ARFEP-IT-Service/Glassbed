/// Texts of the update notice. They live in code (not in assets/i18n/) so that the build
/// without the update check contains none of them.
library;

/// Copies of texts from shared/i18n.json (the same wording as the Windows app). A test keeps
/// them identical to the master; if mobile/assets/i18n/shared.json ever ships them, that wins.
const sharedUpdateTexts = <String, Map<String, String>>{
  'Update': {'en': 'Update', 'de': 'Aktualisieren', 'tr': 'Güncelle'},
  "What's new": {'en': "What's new", 'de': 'Was ist neu', 'tr': 'Yenilikler'},
  'Later': {'en': 'Later', 'de': 'Später', 'tr': 'Sonra'},
  'Skip this version': {
    'en': 'Skip this version',
    'de': 'Diese Version überspringen',
    'tr': 'Bu sürümü atla',
  },
  'Glassbed {version} is available': {
    'en': 'Glassbed {version} is available',
    'de': 'Glassbed {version} ist verfügbar',
    'tr': 'Glassbed {version} kullanıma sunuldu',
  },
  'Check for updates?': {
    'en': 'Check for updates?',
    'de': 'Nach Updates suchen?',
    'tr': 'Güncellemeler denetlensin mi?',
  },
  consentText: {
    'en': consentText,
    'de': 'Glassbed kann auf GitHub nach einer neuen Version suchen – höchstens einmal am Tag. '
        'GitHub sieht dabei deine IP-Adresse. Es wird nichts automatisch installiert; du '
        'entscheidest jedes Mal selbst. Du kannst das später in den Einstellungen ändern.',
    'tr': "Glassbed, GitHub'da yeni bir sürüm olup olmadığına bakabilir – en fazla günde bir kez. "
        'Bu sırada GitHub IP adresinizi görür. Hiçbir şey otomatik olarak yüklenmez; her seferinde '
        'siz karar verirsiniz. Bunu daha sonra ayarlardan değiştirebilirsiniz.',
  },
  'Check for updates': {
    'en': 'Check for updates',
    'de': 'Nach Updates suchen',
    'tr': 'Güncellemeleri denetle',
  },
  settingsHint: {
    'en': settingsHint,
    'de': 'Höchstens einmal am Tag fragt Glassbed bei GitHub, ob es eine neue Version gibt. '
        'GitHub sieht deine IP-Adresse. Es wird nichts automatisch installiert.',
    'tr': "Glassbed en fazla günde bir kez GitHub'a yeni bir sürüm olup olmadığını sorar. "
        'GitHub IP adresinizi görür. Hiçbir şey otomatik olarak yüklenmez.',
  },
  'Check now': {'en': 'Check now', 'de': 'Jetzt suchen', 'tr': 'Şimdi denetle'},
  'Updates': {'en': 'Updates', 'de': 'Updates', 'tr': 'Güncellemeler'},
  'Checking…': {'en': 'Checking…', 'de': 'Suche läuft…', 'tr': 'Denetleniyor…'},
  'Could not check for updates: {error}': {
    'en': 'Could not check for updates: {error}',
    'de': 'Suche nach Updates fehlgeschlagen: {error}',
    'tr': 'Güncellemeler denetlenemedi: {error}',
  },
  'Glassbed {version} is up to date.': {
    'en': 'Glassbed {version} is up to date.',
    'de': 'Glassbed {version} ist aktuell.',
    'tr': 'Glassbed {version} güncel.',
  },
};

/// Texts only the Android update notice uses (German informal, Turkish formal).
/// Privacy sentence under "About" in the github variant (it can also ask GitHub).
const privacyNoteText =
    'Glassbed talks to your printer on the local network – and to GitHub only if you allow the '
    'update check. No accounts, no tracking.';

const mobileUpdateTexts = <String, Map<String, String>>{
  // Only when a release has no checksum file: the APK then opens in the browser.
  'Glassbed {version} is downloading in your browser': {
    'en': 'Glassbed {version} is downloading in your browser',
    'de': 'Glassbed {version} wird im Browser heruntergeladen',
    'tr': 'Glassbed {version} tarayıcıda indiriliyor',
  },
  privacyNoteText: {
    'en': privacyNoteText,
    'de': 'Glassbed spricht mit deinem Drucker im lokalen Netzwerk – und mit GitHub nur, wenn du die '
        'Update-Prüfung erlaubst. Keine Konten, kein Tracking.',
    'tr': 'Glassbed yerel ağdaki yazıcınızla konuşur – GitHub ile ise yalnızca güncelleme denetimine '
        'izin verirseniz. Hesap yok, izleme yok.',
  },
  installHint: {
    'en': installHint,
    'de': 'Installiere danach die heruntergeladene APK – deine Einstellungen bleiben erhalten.',
    'tr': 'Ardından indirilen APK dosyasını yükleyin – ayarlarınız korunur.',
  },
  unknownAppsHint: {
    'en': unknownAppsHint,
    'de': 'Android fragt dabei eventuell, ob dein Browser unbekannte Apps installieren darf.',
    'tr': 'Android, tarayıcınızın bilinmeyen uygulamaları yüklemesine izin vermenizi isteyebilir.',
  },
  downloadingOfText: {
    'en': downloadingOfText,
    'de': 'Glassbed {version} wird heruntergeladen… {done} von {total} MB',
    'tr': 'Glassbed {version} indiriliyor… {done} / {total} MB',
  },
  downloadingText: {
    'en': downloadingText,
    'de': 'Glassbed {version} wird heruntergeladen… {done} MB',
    'tr': 'Glassbed {version} indiriliyor… {done} MB',
  },
  verifyingText: {
    'en': verifyingText,
    'de': 'Download wird geprüft…',
    'tr': 'İndirilen dosya doğrulanıyor…',
  },
  checksumMismatchText: {
    'en': checksumMismatchText,
    'de': 'Der Download passt nicht zu seiner Prüfsumme und wurde gelöscht. Es wurde nichts '
        'installiert.',
    'tr': 'İndirilen dosya sağlama toplamıyla eşleşmedi ve silindi. Hiçbir şey yüklenmedi.',
  },
  allowInstallText: {
    'en': allowInstallText,
    'de': 'Erlaube Glassbed, Updates zu installieren, und tippe dann noch einmal auf '
        '„Aktualisieren“.',
    'tr': "Glassbed'in güncellemeleri yüklemesine izin verin, ardından tekrar \"Güncelle\" "
        'düğmesine dokunun.',
  },
  installStartedText: {
    'en': installStartedText,
    'de': 'Android fragt dich jetzt, ob Glassbed {version} installiert werden soll. Deine '
        'Einstellungen bleiben erhalten.',
    'tr': 'Android şimdi Glassbed {version} sürümünün yüklenip yüklenmeyeceğini soruyor. '
        'Ayarlarınız korunur.',
  },
  downloadFailedText: {
    'en': downloadFailedText,
    'de': 'Download fehlgeschlagen: {error}',
    'tr': 'İndirme başarısız oldu: {error}',
  },
};

const downloadingOfText = 'Downloading Glassbed {version}… {done} of {total} MB';
const downloadingText = 'Downloading Glassbed {version}… {done} MB';
const verifyingText = 'Checking the download…';
const checksumMismatchText =
    'The download does not match its checksum and was deleted. Nothing was installed.';
const allowInstallText = 'Allow Glassbed to install updates, then tap Update again.';
const installStartedText =
    'Android now asks whether to install Glassbed {version}. Your settings are kept.';
const downloadFailedText = 'Download failed: {error}';

const consentText =
    'Glassbed can look for a new version on GitHub – at most once a day. GitHub sees your IP '
    'address when it does. Nothing is installed automatically; you decide each time. You can '
    'change this later in the settings.';
const settingsHint =
    'At most once a day Glassbed asks GitHub whether a new version exists. GitHub sees your IP '
    'address. Nothing is installed automatically.';
const installHint = 'Install the downloaded APK – your settings are kept.';
const unknownAppsHint = 'Android may ask you to allow your browser to install unknown apps.';

/// All texts of the update notice, for i18n.addTexts().
const updateTexts = {...sharedUpdateTexts, ...mobileUpdateTexts};
