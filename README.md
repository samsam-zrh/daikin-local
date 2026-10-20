# Mon climat

J’ai fait cette application pour contrôler mes clims Daikin sur le réseau local. Le projet est parti d’une analyse du fonctionnement de ONECTA et du protocole utilisé par les appareils. Il y a une version web en Python et une app iPhone en SwiftUI.

On peut voir la température de chaque pièce, allumer ou éteindre une unité, changer le mode, la ventilation et la consigne. Après une commande, l’app relit l’état pour vérifier que le réglage a été pris en compte.

## Essayer sans clim

Avec Python 3.9 ou plus récent, depuis le dossier du projet :

```sh
python3 app/server.py --test-fixture app/demo.json --open
```

La démo utilise un appareil fictif en mémoire. On peut changer ses réglages sans toucher au réseau ni à une vraie clim.

## Utiliser la version web

```sh
python3 app/server.py --open
```

L’interface s’ouvre sur <http://127.0.0.1:8770>. Dans **Connexion**, lancer la recherche ou ajouter l’adresse IP de l’appareil. Le Mac et la clim doivent être sur le même réseau. Sur Mac, on peut aussi ouvrir `app/Lancer.command`.

Pour garder une liste d’adresses au démarrage, créer `app/known-devices.json` :

```json
{"hosts": ["192.168.1.20"]}
```

Cette adresse est un exemple, à remplacer par celle de son appareil. Le fichier est ignoré par Git. Sans ce fichier, la liste démarre vide.

La version web n’a pas de dépendance à installer. Le serveur écoute uniquement sur le Mac : elle n’est pas prévue pour être exposée sur Internet.

## Installer sur iPhone

Ouvrir `iphone/MonClimat.xcodeproj` dans Xcode, choisir son équipe dans **Signing & Capabilities**, puis son iPhone comme destination et lancer le projet. iOS 17 minimum.

Au premier lancement, autoriser l’accès au réseau local et ajouter l’adresse de la clim dans **Connexion**. L’iPhone parle directement aux appareils ; le Mac n’a pas besoin de rester allumé. Les adresses sont enregistrées sur l’iPhone.

## Organisation

- `app/controller.py` : découverte des appareils, lecture et envoi des réglages.
- `app/server.py` : serveur HTTP et API locale.
- `app/app.js`, `index.html`, `styles.css` : interface web.
- `iphone/Core/` : protocole et client HTTP en Swift.
- `iphone/App/` : écrans SwiftUI et gestion des pièces.
- `app/tests/` et `iphone/Tests/` : tests avec des appareils fictifs.

## Tests

```sh
cd app
python3 -m unittest discover -s tests -v
cd ..
swift test --package-path iphone
```

Les tests n’envoient aucune commande aux appareils du réseau.

## Compatibilité

Le projet utilise le protocole HTTP local historique de Daikin. Il a été essayé avec des unités FTXA et ne couvre pas tous les modèles compatibles avec ONECTA. Les commandes ont été testées sur simulateur ; les lectures ont aussi été vérifiées sur mes appareils.

Pas de connexion au cloud Daikin, de planning ni de suivi de consommation. C’est un projet personnel, sans affiliation avec Daikin.

## Sources

J’ai utilisé le [manuel de la gamme FTXA](https://www.daikin.eu/content/dam/document-library/user%20reference%20guide/ac/Split/FTXA20-50AW,AT,AS_CTXA15AW,AT,AS_4PFR518786-1B_2018_06_User%20reference%20guide_French.pdf) et consulté [pydaikin](https://github.com/fredrike/pydaikin/blob/87c9e8bc1e35c268feee17ba1b6c46daa1a4627a/pydaikin/daikin_brp069.py) pour comprendre le protocole et les valeurs mémorisées selon le mode. Le client est une implémentation indépendante. Les symboles de l’interface iPhone sont les SF Symbols fournis par Apple.
