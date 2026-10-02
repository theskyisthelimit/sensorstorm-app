# Drittdaten und Drittdienste

## Herstellerliste für Hardware-Adressen (`Resources/oui.bin`)

Die Datei ordnet den Anfangsbytes einer Hardware-Adresse den Namen des Herstellers zu. Sie
enthält die drei Register der IEEE: MA-L (24 Bit, sechs Hexziffern), MA-M (28 Bit, sieben) und
MA-S (36 Bit, neun), zusammen 53 453 Einträge, einen je Zeile (`SCHLÜSSEL<TAB>Name`), nach Bytes
sortiert, roh mit Deflate komprimiert (`NSData.decompressed(using: .zlib)`). Die Suche nimmt den
längsten passenden Schlüssel: viele kleine Hersteller von Sensoren und Steckdosen besitzen nur
einen MA-S-Block innerhalb eines grösseren.

- **Quelle der Daten:** IEEE Registration Authority (<https://standards-oui.ieee.org/>).
- **Aufbereitung des ausgelieferten Stands:** die Zusammenstellung des Projekts *oui-data* von
  silverwind (<https://github.com/silverwind/oui-data>), BSD-Lizenz, mit `Tools/make_oui.py
  --normalise` bereinigt (HTML-Zeichen aufgelöst, „Private" entfernt, nach Bytes sortiert).
- **Lizenz der Aufbereitung (BSD 3-Clause):** Weitergabe in Quell- und Binärform ist mit dem
  Hinweis auf die Urheber erlaubt; der Name der Urheber darf nicht ohne Zustimmung zur Werbung
  verwendet werden. Die Namen der Hersteller selbst sind Marken ihrer Inhaber.
- **Aktualisieren:** die drei CSV-Dateien der IEEE laden (`oui.csv`, `mam.csv`, `oui36.csv`) und
  `Tools/make_oui.py oui.csv mam.csv oui36.csv` aufrufen. Die Tests `ouiLookup`, `ouiCompressed`
  und `shippedList` prüfen Aufbau, Sortierung und die Suche über alle drei Schlüssellängen.
- **Grenzen:** Adressen mit gesetztem „lokal verwaltet“-Bit (Bit 1 des ersten Bytes) haben keinen
  Hersteller, die App sagt „Zufällige Adresse“. Blöcke, die an einen nicht genannten
  Auftraggeber gingen („Private"), fehlen; für sie bleibt der Hersteller leer.

## Netzbetreiber und Land eines Routers (Team Cymru)

Traceroute und die Abfrage der öffentlichen Adresse stellen Namensabfragen an
`<umgekehrte Adresse>.origin.asn.cymru.com` und `AS<Nummer>.asn.cymru.com` (TXT-Einträge).
Die App sendet sie über den DNS-Server des Netzes; sie fragt nur öffentliche Adressen, nie
private, Loopback-, Link-Local- und Carrier-NAT-Adressen. In der Traceroute lässt sich das
abschalten. Der Dienst ist frei nutzbar; für starke Nutzung nennt Team Cymru eigene Regeln
(<https://www.team-cymru.com/ip-asn-mapping>).

## Öffentliche Adresse (Cloudflare)

Die Abfrage `https://1.1.1.1/cdn-cgi/trace` und `https://[2606:4700:4700::1111]/cdn-cgi/trace`
liefert Adresse, Land und Rechenzentrum, nur auf Knopfdruck.
