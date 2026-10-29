// Pure build planner.  No network, uploads or release state changes.
// One shared MERGE-TIMESTAMP build per app across iOS and macOS (owner, Oct 29 2026).
// build = max(S, M + 1), a plain integer, where S is the merge stamp (the
// committer date of the squash-merge commit on main in America/Chicago as
// YYYYMMDDHHMM) and M is the highest first numeric component among EVERY
// known build: every iOS build and every macOS build on ALL trains (expired
// included, old timestamp-style builds included) plus every extra floor.
// A rebuild of the same commit still goes up, because M already holds the
// previous build.  No floor and no cap.  Incomplete or malformed inventory
// throws; nothing is guessed.
export function nextSharedBuild({iosBuilds, macBuilds, extraFloors = [], complete, mergeStamp}) {
  if (complete !== true || !Array.isArray(iosBuilds) || !Array.isArray(macBuilds)) {
    throw new Error('complete build inventory required');
  }
  if (typeof mergeStamp !== 'string' || !/^[1-9][0-9]{11}$/.test(mergeStamp)) {
    throw new Error('malformed merge stamp');
  }
  if (!Array.isArray(extraFloors)) throw new Error('malformed build inventory');
  for (const floor of extraFloors) {
    if (typeof floor === 'number') {
      if (!Number.isSafeInteger(floor) || floor < 0) throw new Error('malformed build inventory');
    } else if (typeof floor === 'string') {
      if (!/^[0-9]+$/.test(floor)) throw new Error('malformed build inventory');
    } else {
      throw new Error('malformed build inventory');
    }
  }
  // Validate everything before computing; malformed evidence is never ignored.
  const re = /^[0-9]+(\.[0-9]+){0,2}$/;
  for (const value of [...iosBuilds, ...macBuilds]) {
    if (typeof value !== 'string' || !re.test(value)) throw new Error('malformed build inventory');
  }
  let next = BigInt(mergeStamp);
  const consider = (first) => {
    const candidate = first + 1n;
    if (candidate > next) next = candidate;
  };
  for (const value of [...iosBuilds, ...macBuilds]) {
    consider(BigInt(value.split('.')[0]));
  }
  for (const floor of extraFloors) {
    consider(BigInt(floor));
  }
  return {build: String(next)};
}
