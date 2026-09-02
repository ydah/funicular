# Instrumentation benchmark

Run the synthetic framework cases without a timing gate:

```sh
bundle exec ruby benchmark/instrumentation.rb
```

Write a machine-local artifact, then compare a later run on the same machine:

```sh
OUTPUT=tmp/instrumentation-before.json bundle exec ruby benchmark/instrumentation.rb
BASELINE=tmp/instrumentation-before.json bundle exec ruby benchmark/instrumentation.rb
```

Set `N` to change the sample count. Release review compares the median delta on
the same machine; CI records results but does not fail on absolute timings.
