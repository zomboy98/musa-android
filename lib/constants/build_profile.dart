/// Public builds ship MUSA as a bare player: no add-ons are packaged and the
/// app expects people to add them by code, file or repository.
const bool isPublicBuild = bool.fromEnvironment('MUSA_PUBLIC');

/// The public release is a beta for testers.
const bool isBetaBuild = true;
