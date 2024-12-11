#HOW TO RUN
 Install gammu programs [HERE](https://docs.gammu.org/quick/index.html#installing-gammu)
``` bash
    sudo apt install gammu gammu-smsd
```
Run gammu-detect to find where the modem is connected

``` bash
    sudo gammu-detect
```

Copy the `gammurc.example` file and change the variables

Run the program one first time to set the configs
``` bash
    python3 venv .venv
    source .venv/bin/activate
    pip install .
    python src/sms.py
```
