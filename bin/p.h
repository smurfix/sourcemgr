#!/bin/sh

cat <<'END'
p.add       neue Dateien hinzuf�gen
p.cvsimport vollst�ndigen CVS-Baum mit allen (externen) Versionen und
            (optional) der neuesten internen Version einchecken
p.del       �bersch�ssige Dateien l�schen
p.diff      Diffs zur letzten Version
p.edit      editiere die .prj-Datei
p.get       holt (noris-)Sourcecode aus dem Archiv
p.import    update externer Sourcen
p.info      Statusinfo eines Archivs
p.init      Initiales Installieren von externem Source im Archiv
p.new       Initiales Installieren von eigenen Sourcen im Archiv
p.make      Hole aus Archiv, baue, installiere, wirf Sourcen wieder weg.
p.merge     Update lokaler Sourcen bei Konflikten beim Checkin
p.oget      holt Original-Sourcecode aus dem Archiv
p.patch     Patchen (normalerweise externer) Sourcen
p.put       Speichern von �nderungen im Archiv
p.rdist     Verteile an alle betroffenen Rechner
p.rmcvs     Rekursives L�schen von CVS-spezifischen Subdirectories
p.update    Update lokaler Sourcen nach externen �nderungen
END
