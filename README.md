# Mon climat

J’ai fait cette app pour contrôler mes clims Daikin en local, après avoir étudié ONECTA et le protocole des appareils. Il y a une version web en Python et une app iPhone en SwiftUI : température, marche/arrêt, mode et ventilation.

## Sur Mac

Python 3.9 minimum, sans dépendance à installer. Depuis la racine du projet :

```sh
# Démo avec une clim fictive
python3 app/server.py --test-fixture app/demo.json --open

# Avec ses appareils
python3 app/server.py --open
```

L’interface est sur <http://127.0.0.1:8770>. Dans **Connexion**, lancer la recherche ou ajouter l’IP de la clim. Les appareils doivent être sur le même réseau. Le serveur reste sur le Mac, sans exposition sur Internet.

Pour mémoriser des adresses, créer `app/known-devices.json` avec `{"hosts": ["192.168.1.20"]}`, en remplaçant l’IP d’exemple. Ce fichier est ignoré par Git.

## Sur iPhone

Ouvrir `iphone/MonClimat.xcodeproj` dans Xcode, choisir son équipe dans **Signing & Capabilities**, puis lancer sur son iPhone (iOS 17 minimum).

Autoriser le réseau local et ajouter l’IP de la clim dans **Connexion**. L’iPhone communique directement avec elle.

## Tests

```sh
cd app
python3 -m unittest discover -s tests -v
cd ..
swift test --package-path iphone
```

Ils utilisent des appareils fictifs. Les lectures ont aussi été vérifiées sur mes unités FTXA ; les commandes ont été testées sur simulateur. Le protocole HTTP local ne couvre pas toutes les clims ONECTA.

## Sources

[manuel de la gamme FTXA](https://www.daikin.eu/content/dam/document-library/user%20reference%20guide/ac/Split/FTXA20-50AW,AT,AS_CTXA15AW,AT,AS_4PFR518786-1B_2018_06_User%20reference%20guide_French.pdf) et [pydaikin](https://github.com/fredrike/pydaikin/blob/87c9e8bc1e35c268feee17ba1b6c46daa1a4627a/pydaikin/daikin_brp069.py) pour comprendre le protocole et les valeurs mémorisées selon le mode. Le client est une implémentation indépendante. Les symboles de l’interface iPhone sont les SF Symbols fournis par Apple.

Projet personnel, sans affiliation avec Daikin.
