#!/usr/bin/env python3
"""Push the App Store listing metadata for Sensorstorm to App Store Connect.

Idempotent: every write is a GET-then-PATCH-or-POST, so running it twice changes
nothing. The listing copy lives in `LISTING` below — this file is the source of
truth for it, not the ASC web UI, so a future version starts from a diff instead
of from a blank text area.

Usage:
  export ASC_KEY_ID=... ASC_ISSUER_ID=...        # see Tools/asc.py
  Tools/asc_metadata.py --dry-run                # show what would change
  Tools/asc_metadata.py
  Tools/asc_metadata.py --support-url https://... --privacy-url https://...
  Tools/asc_metadata.py --attach-build 12        # point the version at a build

Deliberately NOT done here:
  * submitting for review — that stays a human decision;
  * price and territory availability — one-way-ish setup, better done once in
    the UI with the tax/banking forms in front of you;
  * the in-app purchase itself. `ch.sensorstorm.app.pro` (non-consumable) has to
    be created in the ASC web UI, priced there, and submitted *together with*
    the version. Nothing sells until the Paid Applications agreement is signed
    and the tax and banking forms are complete — see RELEASE.md.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc import request  # noqa: E402

APP_ID = "6795648479"
PRIMARY_CATEGORY = "UTILITIES"
SECONDARY_CATEGORY = "PRODUCTIVITY"
VERSION_STRING = "1.0.0"

# App Store locale -> copy.
#
# Eleven locales, one tier. The app's interface ships in all ten languages these listings are
# written in, so each description ends by saying so in its own language — that is a selling
# point, not a disclaimer, and it used to say the opposite.
#
# The rule behind it has not changed: never claim a language the catalog does not carry.
# `CFBundleLocalizations: [de, en]` against an empty string catalog is exactly the mistake
# this app already made for eight builds.
#
# Not zh-Hans: since 2023 the mainland Chinese App Store requires an ICP filing held by a
# Chinese legal entity. zh-Hant (Taiwan, Hong Kong) carries no such requirement.
#
# Limits enforced below: subtitle <= 30 chars, keywords <= 100 *bytes* (accented characters
# cost two, CJK three), promotionalText <= 170, description <= 4000.
#
# Keywords deliberately avoid every word already in the name or the subtitle: Apple indexes
# name, subtitle and keywords as one bag, so repeating "Sensor" or "Logger" there would buy
# nothing and cost bytes that the survey half of the app needs.

_DE_DESCRIPTION = """Dein iPhone als Messgerät. Sensorstorm zeichnet alle Sensoren gleichzeitig auf — und dokumentiert, was du vor Ort vorfindest. Zwei Werkzeuge, eine gemeinsame Uhr.

MESSEN: EINE UHR FÜR ALLES

Ein Tippen startet alles: Beschleunigung, Drehrate, Orientierung, Magnetfeld, GPS, Barometer, Lautstärke, Schritte, Gerätezustand. Dazu auf Wunsch Video in 720p, 1080p oder 4K.

Alle Ströme liegen auf derselben Zeitbasis wie die Videobilder. Ein Bild und der Beschleunigungswert dazu gehören exakt zusammen — ohne Nachkalibrieren, ohne Drift. Dafür gibt es diese App.

Die Bildstabilisierung bleibt bewusst aus: sie würde das Bild von den Bewegungsdaten entkoppeln und jede Auswertung, die beides verbindet, still verfälschen.

VOR ORT: BEOBACHTUNGEN FESTHALTEN

Eine Route ist ein Weg, eine Beobachtung eine Stelle darauf. Dazu beliebig viele Fotos und Clips, eine Bewertung von 1 bis 10 und der markierte Bereich — Kreis oder Polygon.

Bei jeder Beobachtung steht, woher ihre Koordinate stammt: ein GPS-Fix, ein Mittel aus zehn Sekunden Stillstand, oder eine von Hand gesetzte Nadel. Der Unsicherheitskreis wird massstäblich gezeichnet: eine Nadel in einem 30-Meter-Kreis ist eine andere Aussage als eine in einem 3-Meter-Kreis.

Wird von Hand korrigiert, bleiben beide Positionen erhalten: was das GPS sagte, und wo jemand entschied.

WIEDERGEBEN STATT NUR SAMMELN

Jede Aufnahme lässt sich abspielen: Video und Kurven laufen synchron, der Abspielkopf steht in jedem Diagramm an derselben Stelle, daneben die Zahlenwerte zu diesem Zeitpunkt.

AUFGEZEICHNET WERDEN

• Beschleunigung, roh und sensorfusioniert
• Gravitation
• Drehrate, roh und kalibriert
• Orientierung als Roll/Pitch/Yaw und Quaternion
• Magnetfeld, roh und kalibriert
• Kompass, an Nordrichtung ausgerichtet
• Barometer: Luftdruck und Höhe, Nullpunkt setzbar
• GPS: Position, Höhe, Geschwindigkeit, Kurs, je mit Genauigkeit
• Lautstärke in dBFS, Mittelwert und Spitze
• Video mit Ton, Vorder- oder Rückkamera
• Schrittzähler, Aktivität, Batterie, Helligkeit, Netzwerk
• Bluetooth: Geräte in Reichweite und Signalstärke
• AirPods-Kopfbewegung
• Apple Watch: Herzfrequenz und Handgelenkbewegung
• Markierungen mit Zeitstempel und Text

Abtastrate wählbar von 10 bis 400 Hz.

LIVE AN DEINEN SERVER

Auf Wunsch geht jede Messung während der Aufnahme als JSON an eine Adresse deiner Wahl — eigenes Dashboard, Node-RED, Home Assistant. Die Aufzeichnung läuft davon unabhängig: bricht die Verbindung ab, fehlt nichts in der Datei.

EXPORT ZUM WEITERVERWENDEN

Aufnahmen als CSV je Sensor, als kombinierte Tabelle auf gemeinsamem Zeitraster, als JSON, SQLite, Rohdaten, im Sensor-Logger-Layout oder als Gyroflow-Log. Der GPS-Track als GPX oder KML. Routen als GeoJSON für QGIS, als CSV mit WGS84 und LV95 nebeneinander, als GPX, als KML. Alles zusammen als Zip mit manifest.json, das jede Datei mit SHA-256 beschreibt.

FOTOGRAMMETRIE

Im ARKit-Modus wird zu jedem Bild Position, Blickrichtung und Brennweite aufgezeichnet. Der Fotogrammetrie-Export wählt daraus scharfe, verteilte Einzelbilder und schreibt Brennweite, Ort und Blickrichtung ins EXIF — dazu eine Kameratabelle und ein COLMAP-Modell. RealityScan, Metashape und Meshroom importieren sie samt Startwerten. Das 3D-Modell rechnen sie, nicht diese App.

GRATIS UND PRO

Gratis: alle Sensoren, Wiedergabe mit Diagrammen, eine Route, CSV, GPX und KML.

Sensorstorm Pro schaltet den Rest mit einem Kauf frei — kein Abo, keine Verlängerung: 400 Hz, 4K, Fotogrammetrie-Bilder, Kamerafahrt für Blender, Live-Übertragung, kombinierte Tabelle, JSON, SQLite, Rohdaten, Sensor Logger, Gyroflow, unbegrenzt Routen, GeoJSON und Gesamtexport.

CSV, GPX und KML bleiben auch ohne Pro offen. Deine Messungen gehören dir, gekauft oder nicht.

KEINE WOLKE

Alles bleibt auf dem Gerät. Kein Konto, kein Tracking, keine Analyse im Hintergrund. Aufnahmen verlassen das iPhone nur, wenn du sie exportierst. Auch der Kauf braucht kein Konto bei uns.

Sensorstorm gibt es in zehn Sprachen."""

_EN_DESCRIPTION = """Your iPhone as a measuring instrument. Sensorstorm records every sensor at the same time — and documents what you find on site. Two tools, one shared clock.

MEASURING: ONE CLOCK FOR EVERYTHING

One tap starts all of it: acceleration, rotation rate, orientation, magnetic field, GPS, barometer, loudness, steps, device state. Plus video in 720p, 1080p or 4K if you want it.

Every stream sits on the same time base as the video frames. A frame and the acceleration value that belongs to it line up exactly — no calibration step, no drift. That is the whole reason this app exists.

Video stabilization stays off on purpose: it decouples the image from the motion data and would quietly invalidate any analysis that correlates the two.

ON SITE: RECORDING OBSERVATIONS

A route is a path; an observation is a spot on it. It carries any number of photos and clips, a severity from 1 to 10, and the marked area — a circle or a polygon.

Every observation says where its coordinate came from: a single GPS fix, an average over ten seconds of standing still, or a pin placed by hand. The uncertainty circle is drawn to scale: a pin inside a 30-metre circle is a different statement from one inside a 3-metre circle.

Correct a position by hand and both are kept: what the GPS said, and where somebody decided.

PLAYBACK, NOT JUST COLLECTION

Every recording plays back: video and curves run in sync, the playhead sits at the same instant in every chart, and the values for that instant are printed next to it.

WHAT GETS RECORDED

• Acceleration, raw and sensor-fused
• Gravity vector
• Rotation rate, raw and calibrated
• Orientation as roll/pitch/yaw and quaternion
• Magnetic field, raw and calibrated
• Compass, referenced to true north
• Barometer: pressure and altitude, with a settable zero
• GPS: position, altitude, speed, course, each with its accuracy
• Loudness in dBFS, average and peak
• Video with audio, front or back camera
• Pedometer, activity, battery, brightness, network
• Bluetooth: devices in range and signal strength
• AirPods head motion
• Apple Watch: heart rate and wrist motion
• Annotations with timestamp and text

Sample rate selectable from 10 to 400 Hz.

LIVE TO YOUR OWN SERVER

If you want it, every reading goes to an address of your choosing as JSON while the recording runs — your own dashboard, Node-RED, Home Assistant. The recording is independent of it: if the connection drops, nothing is missing from the file.

AN EXPORT YOU CAN ACTUALLY USE

Recordings as one CSV per sensor, as one combined table on a shared time grid, as JSON, as SQLite, as raw data, in Sensor Logger's layout, or as a Gyroflow log. The GPS track as GPX or KML. Routes as GeoJSON for QGIS, as CSV with WGS84 and Swiss LV95 side by side, as GPX, as KML. And all of it as one zip with a manifest.json naming every file with its SHA-256.

PHOTOGRAMMETRY

In ARKit mode the position, viewing direction and focal length are recorded for every frame. The photogrammetry export picks sharp, well-spaced stills and writes focal length, place and viewing direction into their EXIF — alongside a camera table and a COLMAP model. RealityScan, Metashape and Meshroom import the images with those priors. They compute the 3D model; this app does not.

FREE AND PRO

Free: record every sensor, play it back with charts, one route, CSV export, GPX and KML.

Sensorstorm Pro unlocks the rest with a single purchase — no subscription, no renewal: 400 Hz, 4K, photogrammetry images, camera move for Blender, live streaming, the combined table, JSON, SQLite, raw data, Sensor Logger, Gyroflow, unlimited routes, GeoJSON and the full archive export.

CSV, GPX and KML stay open without Pro. Your measurements are yours, bought or not.

NO CLOUD

Everything stays on the device. No account, no tracking, no background analytics. Recordings leave your iPhone only when you export them. The purchase needs no account with us either.

Sensorstorm is available in ten languages."""

LISTING: dict[str, dict[str, str]] = {
    "de-DE": {
        "name": "Sensorstorm: Sensor Logger",
        "subtitle": "Messen und Schäden erfassen",
        "promotionalText": (
            "Alle Sensoren gleichzeitig auf einer Uhr — und Strassenschäden mit ehrlicher "
            "Lagegenauigkeit. Export als CSV, GeoJSON, GPX, KML und nach Blender."
        ),
        "keywords": "Begehung,Schlagloch,Strasse,Vermessung,GeoJSON,GPX,Fotogrammetrie,Datenlogger,Gyroskop,GPS,IMU,CSV",
        "description": _DE_DESCRIPTION,
    },
    "en-US": {
        "name": "Sensorstorm: Sensor Logger",
        "subtitle": "Survey roads, log sensors",
        "promotionalText": (
            "Every sensor at once on one clock — and road defects with honest positional "
            "accuracy. Export to CSV, GeoJSON, GPX, KML and Blender."
        ),
        "keywords": "defect,pothole,inspection,GeoJSON,QGIS,accelerometer,gyroscope,photogrammetry,gpx,GPS,IMU,CSV",
        "description": _EN_DESCRIPTION,
    },
}

# App Store Connect enabled en-GB on this app as well. Same copy apart from spelling —
# a half-filled locale blocks submission.
LISTING["en-GB"] = dict(LISTING["en-US"])
LISTING["en-GB"]["description"] = _EN_DESCRIPTION.replace(
    "Video stabilization stays off", "Video stabilisation stays off")

# --- Listing-only locales. The interface stays German and English, and each description
# --- says so in its own language rather than letting the download find out.

_UI_NOTE = {
    "fr-FR": "L'application est disponible en français, et dans neuf autres langues.",
    "it": "L'app è disponibile in italiano e in altre nove lingue.",
    "es-ES": "La app está disponible en español y en otros nueve idiomas.",
    "nl-NL": "De app is beschikbaar in het Nederlands en in negen andere talen.",
    "pt-BR": "O aplicativo está disponível em português e em outros nove idiomas.",
    "ja": "アプリは日本語を含む10言語に対応しています。",
    "ko": "앱은 한국어를 포함한 10개 언어를 지원합니다.",
    "zh-Hant": "應用程式支援包含繁體中文在內的 10 種語言。",
}

LISTING.update({
    "fr-FR": {
        "name": "Sensorstorm: Sensor Logger",
        "subtitle": "Relevés et capteurs iPhone",
        "promotionalText": (
            "Tous les capteurs sur une même horloge, et les dégradations de chaussée avec "
            "une précision de position honnête. Export CSV, GeoJSON, GPX, KML, Blender."
        ),
        "keywords": "fissure,cadastre,chaussée,nid-de-poule,voirie,GeoJSON,QGIS,accéléromètre,GPS,IMU,CSV",
        "description": """Sensorstorm enregistre simultanément les capteurs de votre iPhone — et documente les dégradations de la chaussée. Deux outils, une seule horloge.

UNE HORLOGE POUR TOUT

Une pression lance tout à la fois : accélération, vitesse de rotation, orientation, champ magnétique, GPS, baromètre, niveau sonore, pas, état de l'appareil. Avec, si vous le souhaitez, une vidéo en 720p, 1080p ou 4K.

Tous les flux partagent la base de temps des images vidéo. Une image et la valeur d'accélération correspondante coïncident exactement — sans recalibrage, sans dérive.

RELEVÉS : DOCUMENTER LES DÉGRADATIONS

Un parcours est un chemin, une observation une dégradation sur ce chemin : photos et clips en nombre libre, une gravité de 1 à 10, et la zone marquée sous forme de cercle ou de polygone.

Chaque observation indique d'où vient sa coordonnée : un point GPS unique, une moyenne sur dix secondes d'immobilité, ou une épingle posée à la main. Le cercle d'incertitude est tracé à l'échelle sur la carte.

EXPORT RÉUTILISABLE

Enregistrements en CSV par capteur, en données brutes, au format Sensor Logger ou en journal Gyroflow. Parcours en GeoJSON pour QGIS, en CSV avec WGS84 et LV95 côte à côte, en GPX, en KML. Et l'ensemble dans une archive ZIP décrite par un manifest.json.

CAMÉRA ANIMÉE

En mode ARKit, la position, la direction de visée et la focale sont enregistrées pour chaque image. L'export produit frames.csv, scene.json, la vidéo et la trace GPS — un module Blender en fait une caméra animée qui suit l'enregistrement réel.

GRATUIT ET PRO

Gratuit : enregistrer tous les capteurs, la relecture avec graphiques, un parcours, l'export CSV.

Sensorstorm Pro déverrouille le reste en un achat unique, sans abonnement : 400 Hz, 4K, pose de caméra pour la 3D, données brutes, caméra animée pour Blender, Sensor Logger, Gyroflow, parcours illimités, GeoJSON/GPX/KML et l'export global.

L'export CSV reste ouvert sans Pro. Vos mesures vous appartiennent, achat ou non.

AUCUN NUAGE

Tout reste sur l'appareil. Aucun compte, aucun pistage, aucune analyse en arrière-plan.

PHOTOGRAMMÉTRIE ET GPX

En mode ARKit, l'export sélectionne des images nettes et bien réparties et inscrit focale, position et direction de visée dans l'EXIF — pour RealityScan, Metashape ou Meshroom. La trace GPS s'exporte directement en GPX ou KML, sans passer par un outil tiers.

{note}""",
    },
    "it": {
        "name": "Sensorstorm: Sensor Logger",
        "subtitle": "Rilievi e sensori iPhone",
        "promotionalText": (
            "Tutti i sensori su un solo orologio, e i dissesti stradali con una precisione "
            "di posizione onesta. Esporta in CSV, GeoJSON, GPX, KML e Blender."
        ),
        "keywords": "crepa,catasto,strada,buca,dissesto,GeoJSON,QGIS,accelerometro,GPS,IMU,CSV",
        "description": """Sensorstorm registra simultaneamente i sensori del tuo iPhone — e documenta i dissesti stradali. Due strumenti, un solo orologio.

UN OROLOGIO PER TUTTO

Un tocco avvia tutto insieme: accelerazione, velocità di rotazione, orientamento, campo magnetico, GPS, barometro, livello sonoro, passi, stato del dispositivo. A richiesta anche video in 720p, 1080p o 4K.

Tutti i flussi condividono la base dei tempi dei fotogrammi video. Un fotogramma e il valore di accelerazione corrispondente combaciano esattamente — senza ricalibrare, senza deriva.

RILIEVI: DOCUMENTARE I DANNI

Un percorso è un tragitto, un'osservazione un punto danneggiato lungo di esso: foto e clip in numero libero, una gravità da 1 a 10 e l'area marcata come cerchio o poligono.

Ogni osservazione dichiara da dove viene la sua coordinata: un singolo fix GPS, una media su dieci secondi di immobilità, oppure uno spillo posato a mano. Il cerchio di incertezza è disegnato in scala sulla mappa.

ESPORTAZIONE RIUTILIZZABILE

Registrazioni in CSV per sensore, in dati grezzi, nel formato Sensor Logger o come log Gyroflow. Percorsi in GeoJSON per QGIS, in CSV con WGS84 e LV95 affiancati, in GPX, in KML. E il tutto in un unico ZIP descritto da un manifest.json.

CAMERA ANIMATA

In modalità ARKit vengono registrate posizione, direzione di ripresa e lunghezza focale per ogni fotogramma. L'esportazione produce frames.csv, scene.json, il video e la traccia GPS — un add-on per Blender ne ricava una telecamera animata che segue la registrazione reale.

GRATIS E PRO

Gratis: registrare tutti i sensori, la riproduzione con i grafici, un percorso, l'esportazione CSV.

Sensorstorm Pro sblocca il resto con un acquisto unico, senza abbonamento: 400 Hz, 4K, posa della fotocamera per il 3D, dati grezzi, camera animata per Blender, Sensor Logger, Gyroflow, percorsi illimitati, GeoJSON/GPX/KML e l'esportazione completa.

L'esportazione CSV resta aperta anche senza Pro. Le tue misure sono tue, acquistate o no.

NESSUNA NUVOLA

Tutto resta sul dispositivo. Nessun account, nessun tracciamento, nessuna analisi in background.

FOTOGRAMMETRIA E GPX

In modalità ARKit l'export sceglie immagini nitide e ben distribuite e scrive lunghezza focale, posizione e direzione di ripresa nell'EXIF — per RealityScan, Metashape o Meshroom. La traccia GPS si esporta direttamente in GPX o KML, senza strumenti di terze parti.

{note}""",
    },
    "es-ES": {
        "name": "Sensorstorm: Sensor Logger",
        "subtitle": "Inspección y sensores",
        "promotionalText": (
            "Todos los sensores en un mismo reloj, y los daños del pavimento con una "
            "precisión de posición honesta. Exporta a CSV, GeoJSON, GPX, KML y Blender."
        ),
        "keywords": "grieta,catastro,carretera,bache,firme,GeoJSON,QGIS,acelerómetro,GPS,IMU,CSV",
        "description": """Sensorstorm registra a la vez los sensores de tu iPhone — y documenta los daños del pavimento. Dos herramientas, un mismo reloj.

UN RELOJ PARA TODO

Un toque lo inicia todo a la vez: aceleración, velocidad de giro, orientación, campo magnético, GPS, barómetro, sonoridad, pasos, estado del dispositivo. Y vídeo en 720p, 1080p o 4K si lo quieres.

Todos los flujos comparten la base de tiempo de los fotogramas. Un fotograma y su valor de aceleración encajan exactamente — sin recalibrar, sin deriva.

INSPECCIONES: DOCUMENTAR DAÑOS

Un recorrido es un camino; una observación, un punto dañado en él: cuantas fotos y clips quieras, una gravedad de 1 a 10 y el área marcada como círculo o polígono.

Cada observación dice de dónde viene su coordenada: un único fix GPS, una media de diez segundos parado, o una chincheta puesta a mano. El círculo de incertidumbre se dibuja a escala sobre el mapa.

EXPORTACIÓN REUTILIZABLE

Grabaciones en CSV por sensor, en datos brutos, en el formato de Sensor Logger o como registro de Gyroflow. Recorridos en GeoJSON para QGIS, en CSV con WGS84 y LV95 en paralelo, en GPX, en KML. Y todo junto en un ZIP descrito por un manifest.json.

CÁMARA ANIMADA

En modo ARKit se registran posición, dirección de vista y distancia focal de cada fotograma. La exportación produce frames.csv, scene.json, el vídeo y la traza GPS — un complemento de Blender lo convierte en una cámara animada que sigue la grabación real.

GRATIS Y PRO

Gratis: grabar todos los sensores, la reproducción con gráficos, un recorrido, la exportación CSV.

Sensorstorm Pro desbloquea el resto con una compra única, sin suscripción: 400 Hz, 4K, pose de cámara para 3D, datos brutos, cámara animada para Blender, Sensor Logger, Gyroflow, recorridos ilimitados, GeoJSON/GPX/KML y la exportación completa.

La exportación CSV sigue abierta sin Pro. Tus mediciones son tuyas, las compres o no.

SIN NUBE

Todo permanece en el dispositivo. Sin cuenta, sin rastreo, sin analítica en segundo plano.

FOTOGRAMETRÍA Y GPX

En modo ARKit la exportación elige imágenes nítidas y bien repartidas y escribe distancia focal, posición y dirección de vista en el EXIF, para RealityScan, Metashape o Meshroom. La traza GPS se exporta directamente en GPX o KML, sin herramientas externas.

{note}""",
    },
    "nl-NL": {
        "name": "Sensorstorm: Sensor Logger",
        "subtitle": "Inspectie en sensoren",
        "promotionalText": (
            "Alle sensoren op één klok, en wegschade met een eerlijke positienauwkeurigheid. "
            "Exporteer naar CSV, GeoJSON, GPX, KML en Blender."
        ),
        "keywords": "scheur,kadaster,wegdek,schade,areaal,GeoJSON,QGIS,versnelling,GPS,IMU,CSV",
        "description": """Sensorstorm legt de sensoren van je iPhone tegelijk vast — en documenteert schade aan het wegdek. Twee gereedschappen, één klok.

ÉÉN KLOK VOOR ALLES

Eén tik start alles tegelijk: versnelling, draaisnelheid, oriëntatie, magnetisch veld, GPS, barometer, geluidsniveau, stappen, apparaatstatus. Desgewenst met video in 720p, 1080p of 4K.

Alle stromen delen de tijdbasis van de videobeelden. Een beeld en de bijbehorende versnellingswaarde vallen exact samen — zonder herkalibratie, zonder drift.

INSPECTIES: SCHADE VASTLEGGEN

Een route is een route, een waarneming een beschadigde plek daarop: onbeperkt foto's en clips, een ernst van 1 tot 10, en het gemarkeerde gebied als cirkel of polygoon.

Elk waarneming vermeldt waar zijn coördinaat vandaan komt: één GPS-fix, een gemiddelde over tien seconden stilstaan, of een met de hand geplaatste speld. De onzekerheidscirkel wordt op schaal op de kaart getekend.

HERBRUIKBARE EXPORT

Opnamen als CSV per sensor, als ruwe data, in de indeling van Sensor Logger of als Gyroflow-log. Routes als GeoJSON voor QGIS, als CSV met WGS84 en LV95 naast elkaar, als GPX, als KML. En alles samen in één ZIP, beschreven door een manifest.json.

GEANIMEERDE CAMERA

In ARKit-modus worden positie, kijkrichting en brandpuntsafstand per beeld vastgelegd. De export levert frames.csv, scene.json, de video en het GPS-spoor — een Blender-add-on maakt daar een geanimeerde camera van die de echte opname volgt.

GRATIS EN PRO

Gratis: alle sensoren opnemen, afspelen met grafieken, één route, CSV-export.

Sensorstorm Pro ontgrendelt de rest met één aankoop, geen abonnement: 400 Hz, 4K, camerapose voor 3D, ruwe data, camerabeweging voor Blender, Sensor Logger, Gyroflow, onbeperkt routes, GeoJSON/GPX/KML en de volledige export.

De CSV-export blijft ook zonder Pro open. Je metingen zijn van jou, gekocht of niet.

GEEN CLOUD

Alles blijft op het apparaat. Geen account, geen tracking, geen analyse op de achtergrond.

FOTOGRAMMETRIE EN GPX

In ARKit-modus kiest de export scherpe, goed verdeelde beelden en schrijft brandpuntsafstand, positie en kijkrichting in de EXIF — voor RealityScan, Metashape of Meshroom. De GPS-track exporteer je direct als GPX of KML, zonder extern gereedschap.

{note}""",
    },
    "pt-BR": {
        "name": "Sensorstorm: Sensor Logger",
        "subtitle": "Vistoria e sensores",
        "promotionalText": (
            "Todos os sensores em um só relógio, e os danos do pavimento com precisão de "
            "posição honesta. Exporte para CSV, GeoJSON, GPX, KML e Blender."
        ),
        "keywords": "trinca,cadastro,pavimento,buraco,rodovia,GeoJSON,QGIS,acelerômetro,GPS,IMU,CSV",
        "description": """O Sensorstorm grava os sensores do seu iPhone ao mesmo tempo — e documenta danos no pavimento. Duas ferramentas, um só relógio.

UM RELÓGIO PARA TUDO

Um toque inicia tudo de uma vez: aceleração, taxa de rotação, orientação, campo magnético, GPS, barômetro, volume sonoro, passos, estado do aparelho. E vídeo em 720p, 1080p ou 4K, se quiser.

Todos os fluxos compartilham a base de tempo dos quadros de vídeo. Um quadro e o valor de aceleração correspondente coincidem exatamente — sem recalibrar, sem deriva.

VISTORIAS: DOCUMENTAR DANOS

Um percurso é um caminho; uma observação, um ponto danificado nele: quantas fotos e clipes quiser, uma gravidade de 1 a 10 e a área marcada como círculo ou polígono.

Cada observação informa de onde vem sua coordenada: um único fix de GPS, uma média de dez segundos parado, ou um alfinete colocado à mão. O círculo de incerteza é desenhado em escala no mapa.

EXPORTAÇÃO REAPROVEITÁVEL

Gravações em CSV por sensor, em dados brutos, no formato do Sensor Logger ou como log do Gyroflow. Percursos em GeoJSON para QGIS, em CSV com WGS84 e LV95 lado a lado, em GPX, em KML. E tudo junto em um ZIP descrito por um manifest.json.

CÂMERA ANIMADA

No modo ARKit, posição, direção de visada e distância focal são gravadas para cada quadro. A exportação produz frames.csv, scene.json, o vídeo e o traço de GPS — um add-on do Blender transforma isso em uma câmera animada que segue a gravação real.

GRÁTIS E PRO

Grátis: gravar todos os sensores, a reprodução com gráficos, um percurso, a exportação CSV.

O Sensorstorm Pro libera o resto com uma compra única, sem assinatura: 400 Hz, 4K, pose de câmera para 3D, dados brutos, câmera animada para Blender, Sensor Logger, Gyroflow, percursos ilimitados, GeoJSON/GPX/KML e a exportação completa.

A exportação CSV continua aberta sem o Pro. Suas medições são suas, compradas ou não.

SEM NUVEM

Tudo permanece no aparelho. Sem conta, sem rastreamento, sem análise em segundo plano.

FOTOGRAMETRIA E GPX

No modo ARKit a exportação escolhe imagens nítidas e bem distribuídas e grava distância focal, posição e direção de visada no EXIF — para RealityScan, Metashape ou Meshroom. A trilha GPS é exportada direto em GPX ou KML, sem ferramentas de terceiros.

{note}""",
    },
    "ja": {
        "name": "Sensorstorm: Sensor Logger",
        "subtitle": "センサー記録と路面点検",
        "promotionalText": (
            "すべてのセンサーを共通の時計で同時記録。路面の損傷は位置精度を隠さず記録します。"
            "CSV、GeoJSON、GPX、KML、Blender へ書き出し。"
        ),
        "keywords": "加速度,測量,亀裂,道路,舗装,地図,GeoJSON,QGIS,GPS,IMU,CSV,気圧",
        "description": """Sensorstorm は iPhone のセンサーを同時に記録し、路面の損傷を記録します。2つの道具が、1つの時計を共有します。

すべてに1つの時計

一度のタップで一斉に開始します。加速度、角速度、姿勢、地磁気、GPS、気圧、音量、歩数、端末の状態。必要なら 720p / 1080p / 4K の動画も同時に。

すべてのストリームは映像フレームと同じ時間基準に乗ります。ある1フレームと、それに対応する加速度の値が正確に一致します。再校正も、ドリフトの補正も要りません。

点検：損傷を記録する

「ルート」は経路、「観測点」はその上の損傷箇所です。観測点には写真とクリップを何枚でも、1〜10 の深刻度、そして円または多角形で示した範囲が付きます。

各観測点は座標の出所を明示します。単発の GPS フィックス、静止 10 秒の加重平均、または手で置いたピン。不確かさの円は地図上に実寸で描かれます。30 m の円の中のピンと 3 m の円の中のピンは、まったく別の主張です。

再利用できる書き出し

記録はセンサーごとの CSV、生データ、Sensor Logger 形式、Gyroflow ログとして。ルートは QGIS 用の GeoJSON、WGS84 と LV95 を併記した CSV、GPX、KML として。すべてをまとめた ZIP には manifest.json が付きます。

アニメーションカメラ

ARKit モードでは、1フレームごとに位置・視線方向・焦点距離を記録します。書き出しは frames.csv、scene.json、動画、GPS トラックを生成し、Blender アドオンが実際の記録に沿ったアニメーションカメラに変換します。

無料版と Pro

無料：全センサーの記録、グラフ付き再生、ルート1件、CSV 書き出し。

Sensorstorm Pro は買い切りで、サブスクリプションではありません。400 Hz、4K、3D 用カメラポーズ、生データ、Blender 用カメラワーク、Sensor Logger、Gyroflow、ルートの無制限作成、GeoJSON / GPX / KML、一括書き出しが有効になります。

CSV 書き出しは Pro なしでも使えます。あなたの測定値はあなたのものです。

クラウドなし

すべて端末内に留まります。アカウントも、トラッキングも、バックグラウンド解析もありません。

フォトグラメトリと GPX

ARKit モードでは、鮮明で適度に間隔をあけた画像を選び、焦点距離・位置・視線方向を EXIF に書き込みます。RealityScan、Metashape、Meshroom 用です。GPS トラックは GPX または KML として直接書き出せます。

{note}""",
    },
    "ko": {
        "name": "Sensorstorm: Sensor Logger",
        "subtitle": "센서 기록과 노면 점검",
        "promotionalText": (
            "모든 센서를 하나의 시계로 동시 기록하고, 노면 손상은 위치 정확도를 숨기지 "
            "않고 기록합니다. CSV, GeoJSON, GPX, KML, Blender로 내보내기."
        ),
        "keywords": "가속도,측량,균열,도로,포장,지도,GeoJSON,QGIS,GPS,IMU,CSV,기압",
        "description": """Sensorstorm은 iPhone의 센서를 동시에 기록하고, 노면 손상을 문서화합니다. 두 가지 도구가 하나의 시계를 공유합니다.

모든 것에 하나의 시계

한 번의 탭으로 전부 함께 시작합니다. 가속도, 각속도, 자세, 자기장, GPS, 기압, 음량, 걸음 수, 기기 상태. 원하면 720p, 1080p, 4K 영상까지.

모든 스트림은 영상 프레임과 같은 시간 기준 위에 놓입니다. 한 프레임과 그에 대응하는 가속도 값이 정확히 맞물립니다. 재보정도, 드리프트 보정도 필요 없습니다.

점검: 손상 기록하기

'경로'는 경로이고, '관측'는 그 위의 손상 지점입니다. 관측에는 사진과 클립을 원하는 만큼, 1에서 10까지의 심각도, 그리고 원 또는 다각형으로 표시한 범위가 붙습니다.

각 관측는 좌표의 출처를 밝힙니다. 단일 GPS 픽스, 10초간 정지 상태의 가중 평균, 또는 손으로 놓은 핀. 불확실성 원은 지도 위에 실제 축척으로 그려집니다.

다시 쓸 수 있는 내보내기

기록은 센서별 CSV, 원시 데이터, Sensor Logger 형식, Gyroflow 로그로. 경로는 QGIS용 GeoJSON, WGS84와 LV95를 나란히 담은 CSV, GPX, KML로. 그리고 전체를 manifest.json이 설명하는 하나의 ZIP으로.

애니메이션 카메라

ARKit 모드에서는 프레임마다 위치, 시선 방향, 초점 거리를 기록합니다. 내보내기는 frames.csv, scene.json, 영상, GPS 트랙을 만들며 Blender 애드온이 이를 실제 기록을 따라가는 애니메이션 카메라로 바꿉니다.

무료와 Pro

무료: 모든 센서 기록, 그래프와 함께 재생, 경로 1건, CSV 내보내기.

Sensorstorm Pro는 구독이 아닌 일회성 구매입니다. 400 Hz, 4K, 3D용 카메라 포즈, 원시 데이터, Blender용 카메라 무브, Sensor Logger, Gyroflow, 경로 무제한, GeoJSON/GPX/KML, 전체 내보내기가 열립니다.

CSV 내보내기는 Pro 없이도 계속 열려 있습니다. 당신의 측정값은 당신의 것입니다.

클라우드 없음

모든 것이 기기 안에 남습니다. 계정도, 추적도, 백그라운드 분석도 없습니다.

포토그래메트리와 GPX

ARKit 모드에서는 선명하고 적절히 떨어진 이미지를 골라 초점 거리, 위치, 시선 방향을 EXIF에 기록합니다. RealityScan, Metashape, Meshroom용입니다. GPS 경로는 GPX 또는 KML로 바로 내보낼 수 있습니다.

{note}""",
    },
    "zh-Hant": {
        "name": "Sensorstorm: Sensor Logger",
        "subtitle": "感測器記錄與路面巡查",
        "promotionalText": (
            "所有感測器共用一個時鐘同步記錄，路面損壞則如實標示定位精度。"
            "可匯出 CSV、GeoJSON、GPX、KML 與 Blender。"
        ),
        "keywords": "加速度,測量,裂縫,道路,鋪面,地圖,GeoJSON,QGIS,GPS,IMU,CSV,氣壓",
        "description": """Sensorstorm 同時記錄 iPhone 的各項感測器，並記錄路面損壞。兩種工具，共用一個時鐘。

一個時鐘涵蓋一切

輕觸一次即同時啟動：加速度、角速度、姿態、磁場、GPS、氣壓、音量、步數、裝置狀態。需要的話還可同時錄製 720p、1080p 或 4K 影片。

所有資料流都落在與影格相同的時間基準上。某一影格與對應的加速度值精確吻合，不需重新校正，也沒有漂移。

路線：記錄損壞

「路線」是一條路徑，「觀測點」是路徑上的損壞點。每個觀測點可附任意多張照片與影片、1 到 10 的嚴重度，以及用圓形或多邊形標出的範圍。

每個觀測點都會說明座標的來源：單次 GPS 定位、靜止十秒的加權平均，或手動放置的圖釘。不確定範圍的圓會按實際比例畫在地圖上。

可再利用的匯出

記錄可匯出為每個感測器一份的 CSV、原始資料、Sensor Logger 格式或 Gyroflow 記錄檔。路線可匯出為 QGIS 用的 GeoJSON、WGS84 與 LV95 並列的 CSV、GPX、KML。全部也可打包成單一 ZIP，並附上 manifest.json。

動態攝影機

在 ARKit 模式下，每一影格的位置、視線方向與焦距都會被記錄。匯出會產生 frames.csv、scene.json、影片與 GPS 軌跡，Blender 附加元件可將其轉為跟隨實際記錄的動態攝影機。

免費與 Pro

免費：記錄所有感測器、含圖表的重播、一條路線、CSV 匯出。

Sensorstorm Pro 為一次買斷，並非訂閱制：400 Hz、4K、3D 用攝影機姿態、原始資料、給 Blender 的運鏡、Sensor Logger、Gyroflow、不限數量的路線、GeoJSON/GPX/KML 與整體匯出。

即使沒有 Pro，CSV 匯出仍然開放。你的量測資料屬於你，買不買都一樣。

沒有雲端

一切都留在裝置上。沒有帳號、沒有追蹤、沒有背景分析。

攝影測量與 GPX

ARKit 模式會挑選清晰且分佈得當的影像，並把焦距、位置與視線方向寫入 EXIF，供 RealityScan、Metashape 或 Meshroom 使用。GPS 軌跡可直接匯出為 GPX 或 KML。

{note}""",
    },
})

for _locale, _note in _UI_NOTE.items():
    LISTING[_locale]["description"] = LISTING[_locale]["description"].format(note=_note)

LIMITS = {"subtitle": 30, "promotionalText": 170, "description": 4000}


def check_limits() -> None:
    """Fail before touching the API, not halfway through it."""
    problems = []
    for locale, copy in LISTING.items():
        for field, limit in LIMITS.items():
            if len(copy.get(field, "")) > limit:
                problems.append(f"{locale}.{field}: {len(copy[field])} chars > {limit}")
        # Keywords are capped in *bytes*: accented characters cost two, CJK three.
        kw_bytes = len(copy.get("keywords", "").encode("utf-8"))
        if kw_bytes > 100:
            problems.append(f"{locale}.keywords: {kw_bytes} bytes > 100")
        # A space after a comma is indexed as part of the next keyword and wastes a byte.
        if re.search(r",\s", copy.get("keywords", "")):
            problems.append(f"{locale}.keywords: whitespace after a comma")
        for word in wasted_keywords(copy):
            problems.append(f"{locale}.keywords: '{word}' is already in the name or subtitle")
    if problems:
        raise SystemExit("copy exceeds App Store limits:\n  " + "\n  ".join(problems))


def wasted_keywords(copy: dict[str, str]) -> list[str]:
    """Keywords that buy nothing because the field is not the only one indexed.

    Apple searches name, subtitle and keywords as a single bag of words, so a term
    repeated from the name is 100 bytes' worth of budget spent on nothing. Latin
    scripts are compared on a five-character stem because Apple stems too — plural
    'sensores' and singular 'sensor' are one term to the index. CJK has no word
    boundaries, so there a substring test is the only one that means anything.
    """
    bag = f"{copy['name']} {copy['subtitle']}".lower()
    wasted = []
    for keyword in copy.get("keywords", "").split(","):
        word = keyword.lower().strip()
        if not word:
            continue
        is_cjk = max(ord(ch) for ch in word) > 0x2E80
        if (is_cjk and word in bag) or (not is_cjk and len(word) >= 5 and word[:5] in bag):
            wasted.append(keyword)
    return wasted


def get(path: str):
    status, raw = request("GET", path)
    if status >= 400:
        raise SystemExit(f"GET {path} failed {status}: {raw}")
    return json.loads(raw)


def write(method: str, path: str, body: dict, label: str, dry_run: bool) -> None:
    if dry_run:
        print(f"  [dry-run] {method} {path}  ({label})")
        return
    status, raw = request(method, path, body)
    if status >= 400:
        raise SystemExit(f"{method} {path} failed {status}: {raw}")
    print(f"  {label}")


def ios_version_id() -> str:
    data = get(f"/v1/apps/{APP_ID}/appStoreVersions?filter[platform]=IOS&limit=10")["data"]
    editable = [v for v in data if v["attributes"]["appStoreState"] == "PREPARE_FOR_SUBMISSION"]
    if not editable:
        raise SystemExit("no editable (PREPARE_FOR_SUBMISSION) iOS version on the app")
    return editable[0]["id"]


def app_info_id() -> str:
    data = get(f"/v1/apps/{APP_ID}/appInfos")["data"]
    editable = [i for i in data if i["attributes"]["state"] == "PREPARE_FOR_SUBMISSION"]
    if not editable:
        raise SystemExit("no editable appInfo on the app")
    return editable[0]["id"]


def sync_categories(info_id: str, dry_run: bool) -> None:
    print("categories")
    body = {"data": {
        "type": "appInfos", "id": info_id,
        "relationships": {
            "primaryCategory": {"data": {"type": "appCategories", "id": PRIMARY_CATEGORY}},
            "secondaryCategory": {"data": {"type": "appCategories", "id": SECONDARY_CATEGORY}},
        },
    }}
    write("PATCH", f"/v1/appInfos/{info_id}", body, f"{PRIMARY_CATEGORY} / {SECONDARY_CATEGORY}", dry_run)


def sync_content_rights(dry_run: bool) -> None:
    print("content rights")
    body = {"data": {"type": "apps", "id": APP_ID,
                     "attributes": {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}}
    write("PATCH", f"/v1/apps/{APP_ID}", body, "does not use third-party content", dry_run)


def sync_version(version_id: str, dry_run: bool) -> None:
    print("version")
    # ASC created the record as "1.0" while every uploaded build carries the
    # marketing version 1.0.0 from project.yml. They have to match or the build
    # cannot be attached.
    body = {"data": {"type": "appStoreVersions", "id": version_id,
                     "attributes": {"versionString": VERSION_STRING, "releaseType": "AFTER_APPROVAL"}}}
    write("PATCH", f"/v1/appStoreVersions/{version_id}", body, f"versionString {VERSION_STRING}", dry_run)


def sync_app_info_localizations(info_id: str, privacy_url: str | None, dry_run: bool) -> None:
    """name + subtitle + privacy policy URL. These live on the appInfo, not on
    the version, because they survive across versions."""
    print("app info localizations (name, subtitle, privacy URL)")
    existing = {loc["attributes"]["locale"]: loc["id"]
                for loc in get(f"/v1/appInfos/{info_id}/appInfoLocalizations?limit=50")["data"]}

    for locale, copy in LISTING.items():
        attrs = {"name": copy["name"], "subtitle": copy["subtitle"]}
        if privacy_url:
            attrs["privacyPolicyUrl"] = privacy_url
        if locale in existing:
            body = {"data": {"type": "appInfoLocalizations", "id": existing[locale], "attributes": attrs}}
            write("PATCH", f"/v1/appInfoLocalizations/{existing[locale]}", body, f"{locale} updated", dry_run)
        else:
            attrs["locale"] = locale
            body = {"data": {"type": "appInfoLocalizations", "attributes": attrs,
                             "relationships": {"appInfo": {"data": {"type": "appInfos", "id": info_id}}}}}
            write("POST", "/v1/appInfoLocalizations", body, f"{locale} created", dry_run)


def sync_version_localizations(version_id: str, support_url: str | None, marketing_url: str | None,
                               dry_run: bool) -> None:
    """description + keywords + promo text + support/marketing URL, per locale."""
    print("version localizations (description, keywords, promo text)")
    existing = {loc["attributes"]["locale"]: loc["id"]
                for loc in get(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations?limit=50")["data"]}

    for locale, copy in LISTING.items():
        attrs = {
            "description": copy["description"],
            "keywords": copy["keywords"],
            "promotionalText": copy["promotionalText"],
        }
        # No "What's New" on a first release — Apple rejects the field there.
        if support_url:
            attrs["supportUrl"] = support_url
        if marketing_url:
            attrs["marketingUrl"] = marketing_url
        if locale in existing:
            body = {"data": {"type": "appStoreVersionLocalizations", "id": existing[locale], "attributes": attrs}}
            write("PATCH", f"/v1/appStoreVersionLocalizations/{existing[locale]}", body,
                  f"{locale} updated", dry_run)
        else:
            attrs["locale"] = locale
            body = {"data": {"type": "appStoreVersionLocalizations", "attributes": attrs,
                             "relationships": {"appStoreVersion": {
                                 "data": {"type": "appStoreVersions", "id": version_id}}}}}
            write("POST", "/v1/appStoreVersionLocalizations", body, f"{locale} created", dry_run)


def attach_build(version_id: str, build_number: str, dry_run: bool) -> None:
    print(f"build {build_number}")
    builds = get(f"/v1/builds?filter[app]={APP_ID}&limit=50"
                 "&fields[builds]=version,processingState,expired")["data"]
    match = [b for b in builds if b["attributes"]["version"] == build_number]
    if not match:
        raise SystemExit(f"build {build_number} not found on the app")
    build = match[0]
    if build["attributes"]["processingState"] != "VALID":
        raise SystemExit(f"build {build_number} is {build['attributes']['processingState']}, not VALID")
    body = {"data": {"type": "builds", "id": build["id"]}}
    write("PATCH", f"/v1/appStoreVersions/{version_id}/relationships/build", body,
          f"attached build {build_number} ({build['id']})", dry_run)


def report(version_id: str, info_id: str) -> None:
    """What still blocks 'Submit for Review'. Cheaper than reading the web UI's
    progressive error list, which only shows a few problems at a time."""
    print("\n--- remaining gaps ---")
    gaps = []

    for loc in get(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations?limit=50")["data"]:
        a, locale = loc["attributes"], loc["attributes"]["locale"]
        for field in ("description", "keywords", "supportUrl"):
            if not a.get(field):
                gaps.append(f"{locale}: {field} missing")
        sets = get(f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")["data"]
        if not sets:
            gaps.append(f"{locale}: no screenshots (run Tools/asc_capture_screenshots.py --upload)")
    for loc in get(f"/v1/appInfos/{info_id}/appInfoLocalizations?limit=50")["data"]:
        a, locale = loc["attributes"], loc["attributes"]["locale"]
        if not a.get("privacyPolicyUrl"):
            gaps.append(f"{locale}: privacyPolicyUrl missing")

    # A missing to-one relationship answers 200 with `data: null`, not 404 —
    # checking only the status code would report this as present.
    status, raw = request("GET", f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail")
    if status >= 400 or not json.loads(raw).get("data"):
        gaps.append("app review contact details missing (name, phone, email)")

    version = get(f"/v1/appStoreVersions/{version_id}"
                  "?fields[appStoreVersions]=versionString,appStoreState")["data"]
    print(f"version {version['attributes']['versionString']} · {version['attributes']['appStoreState']}")

    status, raw = request("GET", f"/v1/appStoreVersions/{version_id}/build")
    if status >= 400 or not json.loads(raw).get("data"):
        gaps.append("no build attached to the version")

    # RELEASE.md advertises this script as the source of truth for the age
    # rating, so report() has to actually check it rather than assume.
    status, raw = request("GET", f"/v1/appInfos/{info_id}/ageRatingDeclaration")
    if status >= 400 or not (json.loads(raw).get("data") or {}).get("attributes", {}).get("ageRatingOverrideV2"):
        gaps.append("age rating declaration not set")

    status, _ = request("GET", f"/v1/appPriceSchedules/{APP_ID}")
    if status >= 400:
        gaps.append("no price schedule (set the price in the ASC web UI)")
    status, raw = request("GET", f"/v1/apps/{APP_ID}/appAvailabilityV2")
    if status >= 400 or not json.loads(raw).get("data"):
        gaps.append("territory availability not configured (ASC web UI → Pricing and Availability)")

    if gaps:
        for gap in gaps:
            print(f"  ✗ {gap}")
    else:
        print("  nothing missing — ready to submit from the ASC web UI")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="print the writes without sending them")
    parser.add_argument("--support-url", help="support page URL (required by Apple)")
    parser.add_argument("--privacy-url", help="privacy policy URL (required by Apple)")
    parser.add_argument("--marketing-url", help="optional marketing page URL")
    parser.add_argument("--attach-build", help="build number (CFBundleVersion) to attach to the version")
    parser.add_argument("--report-only", action="store_true", help="only list what is still missing")
    args = parser.parse_args()

    check_limits()
    version_id = ios_version_id()
    info_id = app_info_id()
    print(f"app {APP_ID} · version {version_id} · appInfo {info_id}\n")

    if not args.report_only:
        sync_version(version_id, args.dry_run)
        sync_categories(info_id, args.dry_run)
        sync_content_rights(args.dry_run)
        sync_app_info_localizations(info_id, args.privacy_url, args.dry_run)
        sync_version_localizations(version_id, args.support_url, args.marketing_url, args.dry_run)
        if args.attach_build:
            attach_build(version_id, args.attach_build, args.dry_run)

    if not args.dry_run:
        report(version_id, info_id)


if __name__ == "__main__":
    main()
