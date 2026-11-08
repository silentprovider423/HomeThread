#!/usr/bin/env python3
"""Baut Resources/Localizable.xcstrings aus den beim Bauen extrahierten Texten (deutsche Schlüssel) + englischer Übersetzung,
dazu Resources/InfoPlist.xcstrings für die Berechtigungs-Texte.
Aufruf nach einem iOS- und einem Mac-Build:  python3 tools/strings.py   (meldet fehlende Übersetzungen)"""
import glob, json, os, sys

EN = {
    "%lld Mitglieder": "%lld members", "Archivierte Chats": "Archived Chats", "Bearbeitet %@": "Edited %@", "Details": "Details",
    "Emoji": "Emoji", "Fehler": "Error", "Gestern, %@": "Yesterday, %@", "Ich": "Me",
    "Lege mit ⌘N einen Chat oder mit ⇧⌘N eine Gruppe an.": "Create a chat with ⌘N or a group with ⇧⌘N.",
    "Neue Nachricht": "New Message", "Neue Nachricht…": "New message…", "Nicht mehr verfügbar": "No longer available",
    "Suche leeren": "Clear Search", "Suchen…": "Search…", "Weitere": "More",
    "%lld neu von anderem Gerät": "%lld new from another device", "%lld Änderungen warten": "%lld changes waiting",
    "Abbrechen": "Cancel", "Abgeglichen": "Up to date", "Abgleich": "Sync", "Abgleich läuft …": "Syncing…",
    "Ablegen": "Add", "Abmelden": "Sign Out", "Abmelden?": "Sign out?", "Abspielen": "Play",
    "Abstimmung": "Poll", "Abstimmung anlegen": "New Poll", "Abstimmung beenden": "End Poll", "Abstimmungen": "Polls",
    "Adresse oder Ort suchen": "Search for an address or place", "Aktuelles Passwort": "Current Password",
    "Alle Einträge löschen": "Delete All Entries", "Alle Einträge löschen?": "Delete all entries?", "Alle anzeigen": "Show All",
    "Alles": "All",
    "Alles bleibt auf deinem Server. Auf diesem Gerät werden die lokalen Daten gelöscht; noch nicht abgeglichene Änderungen gehen verloren.":
        "Everything stays on your server. The local data on this device will be deleted; changes that haven't synced yet will be lost.",
    "Alles liegt zuerst auf diesem Gerät. Bei Verbindung gleicht die App alle 15 Sekunden mit deinem Server ab.":
        "Everything is saved on this device first. While connected, the app syncs with your server every 15 seconds.",
    "Als gesehen markieren": "Mark as Seen", "Als neu": "Mark New", "Als neu markieren": "Mark as New",
    "Angeheftet": "Pinned", "Angeheftet (%lld/%lld)": "Pinned (%lld/%lld)", "Angelegt am %@": "Created on %@",
    "Anhang": "Attachment", "Anheften": "Pin", "Anmelden": "Sign In",
    "Anmeldung abgelaufen oder Gerät abgemeldet.": "Session expired or device signed out.", "Antwort auf": "Reply to",
    "Antwort hinzufügen": "Add answer", "Antworten": "Answers", "Archiv": "Archive", "Archiv ist leer": "Archive is empty",
    "Archivieren": "Archive", "Archiviert": "Archived", "Archivierte Chats erscheinen hier.": "Archived chats appear here.",
    "Auf deinem Server gibt es noch keine weiteren Personen. Du kannst die Gruppe trotzdem als Themen-Raum für dich anlegen und später Personen hinzufügen.":
        "There are no other people on your server yet. You can still create the group as a topic room for yourself and add people later.",
    "Aus Fotos wählen": "Choose from Photos", "Automatisch": "Automatic",
    "Außerhalb des Heimnetzes nur mit https:// möglich.": "Outside your home network only https:// is allowed.",
    "Bearbeiten": "Edit", "Beenden": "End", "Beendet · %lld Stimme(n)": "Ended · %lld vote(s)", "Benutzername": "Username",
    "Benutzername, Passwort oder Code falsch.": "Wrong username, password or code.",
    "Benutzername, Passwort oder Code falsch. Noch %lld Versuch(e).": "Wrong username, password or code. %lld attempt(s) left.",
    "Bereich": "Scope", "Beschreibung (optional)": "Description (optional)", "Bild entfernen": "Remove Picture",
    "Bild wählen": "Choose Picture", "Bild ändern": "Change Picture", "Chat": "Chat", "Chat als Datei sichern": "Save Chat as File",
    "Chat löschen?": "Delete chat?", "Chat mit allen Einträgen löschen": "Delete Chat and All Entries",
    "Chat nicht gefunden": "Chat not found", "Chat · nur für dich": "Chat · just for you", "Chat-Info": "Chat Info",
    "Chats": "Chats", "Checkliste": "Checklist", "Checkliste anlegen": "New Checklist", "Checklisten": "Checklists",
    "Code aus der Authenticator-App": "Code from your authenticator app", "Darauf antworten": "Reply", "Darstellung": "Appearance",
    "Das Passwort braucht mindestens 12 Zeichen.": "The password needs at least 12 characters.", "Datei": "File",
    "Datei anhängen": "Attach File", "Dateien & Sprachnotizen": "Files & Voice Notes", "Datum eintragen": "Insert Date",
    "Deine Notizen als Chats – nur auf deinen Geräten und deinem Server.": "Your notes as chats – only on your devices and your server.",
    "Der Chat wird auf allen deinen Geräten und auf dem Server gelöscht.": "The chat will be deleted on all your devices and on the server.",
    "Der Raum und alle Einträge werden auf allen Geräten und auf dem Server gelöscht.":
        "The room and all entries will be deleted on all devices and on the server.",
    "Die App spricht nur mit deinem Server. Es werden keine Nachrichten an andere verschickt.":
        "The app only talks to your server. Nothing is ever sent to other people.",
    "Die Datei ist zu groß (höchstens 95 MB).": "The file is too large (95 MB max).",
    "Die Einträge werden auf allen Geräten und auf dem Server gelöscht.": "The entries will be deleted on all devices and on the server.",
    "Die Nadel in der Mitte wird festgehalten.": "The pin in the middle is saved.",
    "Die Server-Adresse ist ungültig.": "The server address is invalid.", "Dieses Gerät": "This device",
    "Dieses Gerät wurde abgemeldet. Bitte neu anmelden.": "This device was signed out. Please sign in again.",
    "Du (%@)": "You (%@)", "Dunkel": "Dark",
    "Ein Chat ist ein Notiz-Raum nur für dich – auf allen deinen Geräten.": "A chat is a note room just for you – on all your devices.",
    "Einstellungen": "Settings", "Eintrag": "Entry", "Eintrag auf allen Geräten löschen?": "Delete entry on all devices?",
    "Eintrag nicht gefunden": "Entry not found", "Einträge": "Entries", "Entfernen": "Remove", "Entwurf: ": "Draft: ",
    "Erlaube den Mikrofonzugriff in den Einstellungen, um Sprachnotizen aufzunehmen.":
        "Allow microphone access in Settings to record voice notes.",
    "Erledigte ausblenden": "Hide Done", "Erledigte zeigen": "Show Done", "Erneut versuchen": "Try Again", "Erstellen": "Create",
    "Ersteller": "Creator", "Fertig": "Done", "Foto": "Photo", "Foto oder Video aufnehmen": "Take Photo or Video",
    "Fotos, Videos und Dateien bleiben auf dem Server und werden bei Bedarf neu geladen. Noch nicht hochgeladene bleiben erhalten.":
        "Photos, videos and files stay on the server and are downloaded again when needed. Files not uploaded yet are kept.",
    "Frage, z. B. Was kochen wir am Sonntag?": "Question, e.g. What should we cook on Sunday?",
    "Frühere Einträge laden": "Load Earlier Entries", "Gelöscht": "Deleted", "Gelöschter Eintrag": "Deleted entry",
    "Gemerkt": "Starred", "Gerät umbenennen": "Rename Device", "Geräte": "Devices", "Gesehen": "Seen", "Gestern": "Yesterday",
    "Gruppe · nur du": "Group · just you", "Gruppe · %lld Personen": "Group · %lld people",
    "Gruppe mit allen Einträgen löschen": "Delete Group and All Entries", "Gruppe · %lld Person(en)": "Group · %lld person(s)",
    "Gruppen sind Themen-Räume. Personen deines Servers kannst du jederzeit hinzufügen.":
        "Groups are topic rooms. You can add people from your server at any time.",
    "Gruppen-Info": "Group Info", "Halte einen Eintrag gedrückt und wähle „Merken“.": "Touch and hold an entry and choose “Star”.",
    "Hell": "Light", "Heruntergeladene Dateien": "Downloaded Files", "Heruntergeladene Dateien entfernen": "Remove Downloaded Files",
    "Heute": "Today", "HomeThread": "HomeThread",
    "HomeThread ist ein unabhängiges Open-Source-Projekt (MIT-Lizenz). Es verschickt nichts an andere – Chats und Gruppen sind Notiz-Räume auf deinem eigenen Server.":
        "HomeThread is an independent open-source project (MIT license). It never sends anything to other people – chats and groups are note rooms on your own server.",
    "Im Chat suchen": "Search in Chat", "In Chat umwandeln": "Convert to Chat", "In Gruppe umwandeln": "Convert to Group",
    "In allen Chats suchen": "Search all chats", "In der Liste oben anheften": "Pin to Top of List",
    "In diesem Chat suchen": "Search this chat", "Infos": "Info", "Inhalte": "Contents",
    "Jedes Gerät hat eine eigene Anmeldung. Ein verlorenes Gerät kannst du hier abmelden.":
        "Every device has its own sign-in. You can sign out a lost device here.",
    "Jetzt abgleichen": "Sync Now", "Kamera": "Camera", "Kein Chat ausgewählt": "No Chat Selected",
    "Kein Zugriff auf das Mikrofon": "No microphone access",
    "Kein Zugriff auf den Standort – verschiebe die Karte oder suche einen Ort.": "No location access – move the map or search for a place.",
    "Keine Medien": "No Media", "Keine Verbindung zum Server": "No connection to the server",
    "Keine weiteren Personen auf deinem Server.": "No other people on your server.", "Konto": "Account", "Kopieren": "Copy",
    "Lege einen Chat oder eine Gruppe an – zum Beispiel „Einkauf“, „Ideen“ oder „Urlaub“.":
        "Create a chat or a group – for example “Groceries”, “Ideas” or “Holidays”.",
    "Löschen": "Delete", "Lösen": "Unpin", "Medien": "Media", "Medien & Dateien": "Media & Files",
    "Mehrere Antworten erlauben": "Allow Multiple Answers", "Mehrere Antworten möglich": "Multiple answers allowed", "Merken": "Star",
    "Mit ↩ ablegen (sonst ⌘↩)": "Return adds entry (otherwise ⌘↩)",
    "Nach drei falschen Codes ist das Zurücksetzen 10 Minuten gesperrt. Danach sind alle Geräte abgemeldet.":
        "After three wrong codes, resetting is locked for 10 minutes. Afterwards all devices are signed out.",
    "Name": "Name", "Name der Gruppe": "Group name", "Name des Chats": "Chat name", "Name des Orts (optional)": "Place name (optional)",
    "Neu": "New", "Neu von anderem Gerät (%lld)": "New from Other Device (%lld)", "Neue Gruppe": "New Group", "Neuer Chat": "New Chat",
    "Neues Passwort (mind. 12 Zeichen)": "New password (at least 12 characters)", "Neues Passwort wiederholen": "Repeat new password",
    "Nicht mehr merken": "Unstar", "Noch keine Chats": "No Chats Yet", "Noch keine Einträge": "No entries yet",
    "Noch nichts gemerkt": "Nothing Starred Yet", "Notiz schreiben …": "Write a note…", "OK": "OK", "Oben anheften": "Pin to Top",
    "Offline – Änderungen werden später abgeglichen": "Offline – changes will sync later", "Ort": "Place", "Ort festhalten": "Add Location",
    "Orte": "Places", "Passwort": "Password",
    "Passwort geändert. Bitte mit dem neuen Passwort anmelden (nächsten Code abwarten).":
        "Password changed. Please sign in with the new password (wait for the next code).",
    "Passwort vergessen?": "Forgot password?", "Passwort zurücksetzen": "Reset Password", "Passwort ändern": "Change Password",
    "Passwort ändern …": "Change Password…", "Pause": "Pause", "Person": "Person", "Person hinzufügen": "Add Person",
    "Personen": "People", "Personen (%lld)": "People (%lld)", "Personen auswählen": "Choose People", "Punkt hinzufügen": "Add item",
    "Punkt löschen": "Delete Item", "Punkte": "Items", "Schließen": "Close", "Server": "Server", "Server-Adresse": "Server address",
    "Serverfehler (%lld): %@": "Server error (%lld): %@", "Setzen": "Set", "Sichern": "Save", "Speicher": "Storage",
    "Sprachnotiz": "Voice note", "Sprachnotiz ablegen": "Add Voice Note", "Sprachnotiz aufnehmen": "Record Voice Note",
    "Status": "Status", "Suchen": "Search", "Teilen …": "Share…", "Texte": "Text",
    "Texte, Checklisten-Punkte, Antworten, Orte und Dateinamen.": "Text, checklist items, answers, places and file names.",
    "Tippen zum Abstimmen": "Tap to vote", "Titel, z. B. Einkauf": "Title, e.g. Groceries", "Umbenennen": "Rename",
    "Version": "Version", "Verwerfen": "Discard", "Video": "Video", "Wartende Änderungen": "Pending changes", "Weiter": "Next",
    "Weitere Reaktionen": "More Reactions", "Wirklich löschen?": "Really delete?",
    "Wähle links einen Chat oder lege mit ⌘N einen neuen an.": "Pick a chat on the left or create a new one with ⌘N.",
    "Zu viele Anfragen – bitte kurz warten.": "Too many requests – please wait a moment.",
    "Zu viele Fehlversuche. Gesperrt für noch %lld Min.": "Too many failed attempts. Locked for %lld more min.",
    "Zuletzt abgeglichen": "Last synced", "Zuletzt aktiv: %@": "Last active: %@", "Zurückholen": "Restore",
    "Zwischenstand zeigen": "Show Live Results", "bearbeitet": "edited", "gesichert": "saved", "von anderem Gerät": "from another device",
    "wartet auf Abgleich": "waiting to sync", "Über": "About", "Überspringen": "Skip",
    "„%@“ mit allen Einträgen löschen": "Delete “%@” and All Entries",
}
SKIP = {"", "%lld", "%lld/%lld", "0", "99+", "@%@"}
INFOPLIST = {
    "NSCameraUsageDescription": "So you can take photos and videos directly into a chat.",
    "NSPhotoLibraryUsageDescription": "So you can add photos and videos to a chat.",
    "NSMicrophoneUsageDescription": "So you can record voice notes.",
    "NSLocationWhenInUseUsageDescription": "So you can save your current location in a chat.",
    "NSLocationUsageDescription": "So you can save your current location in a chat.",
    "NSLocalNetworkUsageDescription": "Connection to your HomeThread server on your home network.",
}

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
keys = set()
for f in glob.glob(os.path.join(root, "build/Build/Intermediates.noindex/HomeThread.build/*/HomeThread*.build/Objects-normal/*/*.stringsdata")):
    for t, entries in json.load(open(f)).get("tables", {}).items():
        if t == "Localizable":
            keys |= {e["key"] for e in entries}
if not keys:
    sys.exit("Keine extrahierten Texte gefunden – erst bauen.")
missing = sorted(k for k in keys - SKIP if k not in EN)
strings = {}
for k in sorted(keys | SKIP):
    if k in SKIP:
        strings[k] = {"shouldTranslate": False}
        continue
    # Deutsch ausdrücklich mit eintragen – sonst baut Xcode kein de.lproj und deutsche Geräte bekommen Englisch
    strings[k] = {"localizations": {
        "de": {"stringUnit": {"state": "translated", "value": k}},
        "en": {"stringUnit": {"state": "translated", "value": EN.get(k, k)}}}}
with open(os.path.join(root, "Resources/Localizable.xcstrings"), "w") as fh:
    json.dump({"sourceLanguage": "de", "strings": strings, "version": "1.0"}, fh, ensure_ascii=False, indent=2, sort_keys=True)

# Berechtigungs-Texte: deutscher Text aus project.yml, englisch von hier
import re
yml = open(os.path.join(root, "project.yml")).read()
de = dict(re.findall(r'(NS\w+UsageDescription): "([^"]+)"', yml))
info = {k: {"localizations": {"de": {"stringUnit": {"state": "translated", "value": v}},
                              "en": {"stringUnit": {"state": "translated", "value": INFOPLIST[k]}}}} for k, v in de.items()}
with open(os.path.join(root, "Resources/InfoPlist.xcstrings"), "w") as fh:
    json.dump({"sourceLanguage": "de", "strings": info, "version": "1.0"}, fh, ensure_ascii=False, indent=2, sort_keys=True)
print(f"{len(keys)} Texte, fehlend: {missing}" if missing else f"{len(keys)} Texte, alle übersetzt")
sys.exit(1 if missing else 0)
