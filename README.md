# HOW TO RUN

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

## e-SIM usage

You can  buy a EUICC sim card from [AliExpress](https://aliexpress.com/item/1005008298268854.html) and a USB reader from [AliExpress](https://aliexpress.com/item/4000618742328.html).
and use the https://github.com/EsimMoe/MiniLPA to create a e-sim profile. So we can use the your e-sim as sim card within the modem.
