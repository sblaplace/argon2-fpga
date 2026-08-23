VERILATOR_SETUP ?= ./scripts/setup_verilator.sh

.PHONY: test vectors sim sim-np8 sim-verilator sim-verilator-np8 clean

test:
	python3 -m unittest discover -s tests -v

vectors:
	python3 -m tests.dump_vectors

sim:
	$(MAKE) -C sim

sim-np8:
	$(MAKE) -C sim NP=8

sim-verilator:
	$(VERILATOR_SETUP) --run $(MAKE) -C sim SIM=verilator

sim-verilator-np8:
	$(VERILATOR_SETUP) --run $(MAKE) -C sim SIM=verilator NP=8

clean:
	$(MAKE) -C sim clean
	find . -name '__pycache__' -type d -exec rm -rf {} +
