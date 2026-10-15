# FIDO V3 (WITCHER) SV kit - shortcuts for the run scripts (every run = new folder in runs/)
#   make run    CFG=pg_fine OPT=B TEST=6 SEED=3 WAVES=1
#   make all    OPT=A
#   make seeds  CFG=all FIRST=1 LAST=20
#   make icarus CFG=all
#   make new    OPT=B            (the 4 CG+PG / CG+PG+ML configurations)
#   make mltrain                 (retrain the ML models from traces, install them)
#   make optionA                 (rebuild the Option A files from optionB_common)
#   make clean  (libraries only)      make distclean  (whole runs/ folder)
CFG ?= cg_fine
OPT ?= A
TEST ?=
SEED ?=
WAVES ?=
FIRST ?= 1
LAST ?= 10
T := $(if $(TEST),-t $(TEST))
S := $(if $(SEED),-s $(SEED))
W := $(if $(WAVES),-w)

run:
	./run_xrun.sh -c $(CFG) -o $(OPT) $(T) $(S) $(W)
all:
	./run_all.sh -o $(OPT) $(T) $(S)
new:
	./run_all.sh -k new -o $(OPT) $(T) $(S)
old:
	./run_all.sh -k old -o $(OPT) $(T) $(S)
mltrain:
	./run_ml_train.sh -i
seeds:
	./run_seeds.sh -c $(CFG) -o $(OPT) -f $(FIRST) -l $(LAST)
icarus:
	./run_icarus.sh -c $(CFG) -o $(OPT) $(T) $(S)
optionA:
	python3 tools/build_optionA.py .
clean:
	./clean.sh -l
distoptionA:
	python3 tools/build_optionA.py .
clean:
	./clean.sh -a

.PHONY: run all new old mltrain seeds icarus optionA clean distclean
