#!/bin/bash

cat <<'END'
p.add       neue Dateien hinzufügen
p.cvsimport vollständigen CVS-Baum mit allen (externen) Versionen und
            (optional) der neuesten internen Version einchecken
p.del       Überschüssige Dateien löschen
p.diff      Diffs zur letzten Version
p.edit      editiere die .prj-Datei
p.get       holt (noris-)Sourcecode aus dem Archiv
p.import    update externer Sourcen
p.info      Statusinfo eines Archivs
p.init      Initiales Installieren von externem Source im Archiv
p.name      gibt den Namen des aktuellen Projekts aus, oder exit 1
p.new       Initiales Installieren von eigenen Sourcen im Archiv
p.make      Hole aus Archiv, baue, installiere, wirf Sourcen wieder weg.
p.merge     Update lokaler Sourcen bei Konflikten beim Checkin
p.oget      holt Original-Sourcecode aus dem Archiv
p.patch     Patchen (normalerweise externer) Sourcen
p.put       Speichern von Änderungen im Archiv
p.rcvsget   updatet PRCS aus Remote-CVS
p.rrcvsget  updatet PRCS aus lokalem CVS, gespiegelt via rsync
p.rdist     Verteile an alle betroffenen Rechner
p.rmcvs     Rekursives Löschen von CVS-spezifischen Subdirectories
p.scvsget   updatet PRCS aus CVSUP
p.unchecked Listet fertiggebaute aber noch vorhandene Verzeichnisse
p.version   holt aktuelle Version aus der .prj-Datei
END
