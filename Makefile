.PHONY: test vectors sim clean

test:
	python3 -m unittest discover -s tests -v

vectors:
	python3 -m tests.dump_vectors

sim:
	$(MAKE) -C sim

clean:
	$(MAKE) -C sim clean
	find . -name '__pycache__' -type d -exec rm -rf {} +
