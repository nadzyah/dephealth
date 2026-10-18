# dephealth

Forecasts how open-source libraries develop over time and how likely they are to
be left without maintainers.

It joins two sources of behavioural data by repository, the daily download
statistics published by the crates.io registry and the public contributor
activity recorded in GH Archive. From those it estimates how the adoption of a
library will change over the next 3 to 12 months, the probability that a project
loses its active maintainers within a year, and anomalies in download series.

You upload a dependency file and get the dependency tree ranked by risk, with a
forecast and an explanation for each library.
