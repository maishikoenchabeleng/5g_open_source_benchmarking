
# Analysis Notebooks

Jupyter notebooks used to produce the figures and summary tables in the report from the data in `results/`.

| Notebook | Phase | Produces |
|---|---|---|
| `ueransim_plots.ipynb` | 1 (simulation) | All UERANSIM results |
| `user_plane_plots.ipynb` | 1 (simulation) | User-plane figures for the OCUDU + srsUE and OAI + nrUE groups |
| `resource_combined_plots.ipynb` | 1 (simulation) | Resource-usage figures for the OCUDU and OAI groups |
| `hardware_plots.ipynb` | 2 (hardware) | All hardware figures and tables|

## How to run

1. Install the required packages:
   `pip install matplotlib pandas scipy jupyter`
2. Open a notebook from this folder and run all cells from top to bottom.

Each notebook reads the raw data from `../results/` and saves its figures as PNG and PDF files in a `figures/` folder next to the notebook.

## Notes

- Power is recalculated from the raw RAPL files as total energy (J) divided by duration (s), instead of using the whole-watt values in the CSV files.
