# Real-target benchmark status

The earlier probe recorded spot checks for KeelMatrix.Redaction, RichardSzalay.MockHttp, Newtonsoft.Json, and KeelMatrix.QueryWatch. Those rows are not reproducible from this repository: the exact package/source hashes, source commit references, configuration files, commands, and raw result artifacts were not committed.

They are therefore intentionally unverified and excluded from the committed synthetic evidence set. They must not be described as trustworthy equivalence evidence or used to claim real-library value. A future real-target benchmark may restore that evidence only after committing disposable inputs, exact versions and hashes, source refs for local builds, commands, and the raw result artifact.

The committed and rerunnable benchmark for this ref is the synthetic recipe in [`Run-Benchmark.ps1`](Run-Benchmark.ps1), with its exact scenario expectations in [`corpus/manifest.json`](corpus/manifest.json) and raw output in [`results/synthetic-benchmark.json`](results/synthetic-benchmark.json).
