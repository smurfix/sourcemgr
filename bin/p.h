#!/bin/sh

cat <<'END'
p.add   neue Dateien hinzuf|gen
p.del   |bersch|ssige Dateien lvschen
p.diff  Diffs zur letzten Version
p.edit  editiere die .prj-Datei
p.get   holt (noris-)Sourcecode aus dem Archiv
p.import        update externer Sourcen
p.info  Statusinfo eines Archivs
p.init  Initiales Installieren von externem Source im Archiv
p.new   Initiales Installieren von eigenen Sourcen im Archiv
p.merge Update lokaler Sourcen bei Konflikten beim Checkin
p.oget  holt Original-Sourcecode aus dem Archiv
p.put   Speichern von Dnderungen im Archiv
p.rmcvs Rekursives Lvschen von CVS-spezifischen Subdirectories
p.update        Update lokaler Sourcen nach externen Dnderungen
END
