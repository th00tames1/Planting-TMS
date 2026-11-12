# Current device checks

prepare_action_probe.py copies current activity capture into an isolated Android QA package. Production identity and records remain untouched. package_ios_source.py and validate_ios.sh support the separate Mac/iOS source check. clock_probe.c checks the public Android sleep-inclusive clock.

Legacy SQLite study/export/soak probes were removed with the previous stopwatch workflow. Their dated reports remain historical evidence under artifacts; they do not validate the current CSV recorder. Keep generated measurements out of the installed production app.
