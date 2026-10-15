# app2 foundation and first vertical slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `app2` Android project (modules, design system, deal-model rules, fake data with a simulator) and one working slice, Home → Listing detail → Chat, that matches the HTML mockups.

**Architecture:** Multi-module Gradle project after Now in Android: plain-Kotlin `:core:model` (the API contract) and `:core:domain` (deal rules), `:core:data` (repository interfaces, fakes, fixtures, simulator), `:core:designsystem` (Compose theme and components), `:core:navigation` (routes), `:core:testing`, three feature modules and `:app`. Screens use ViewModel + `StateFlow`, Hilt, and Navigation 3.

**Tech Stack:** Kotlin 2.4.21, AGP 9.4.1 (built-in Kotlin), Gradle 9.7.0, JDK 21, Compose BOM 2026.09.00 with material3 1.5.0-beta01, Navigation 3 1.2.0, Hilt 2.60.1 + KSP 2.3.12, kotlinx.coroutines 1.11.0, kotlinx.serialization 1.11.0, Coil 3.6.3, DataStore 1.2.1, JUnit 4.13.2, Truth 1.4.5, Turbine 1.2.1, Robolectric 4.17, Roborazzi 1.76.0.

**Spec:** `/home/beanbocchi/shopnexus/specs/2026-10-15-app2-foundation-design.md`. The visual source of truth is `app2/.superdesign/design-system.md`, the HTML in `app2/.superdesign/tmp/*.html`, and the tokens in `app2/.superdesign/tools/common.py`. Read the spec before Task 1.

## Global Constraints

- Android only, native Kotlin. minSdk 31, compileSdk 36, targetSdk 36.
- Java and Kotlin target 21 everywhere (`JavaVersion.VERSION_21`, JVM toolchain 21).
- AGP 9 built-in Kotlin: never apply `org.jetbrains.kotlin.android`.
- Package root `vn.shopnexus`; applicationId `vn.shopnexus.app2`; module namespaces `vn.shopnexus.<layer>.<name>` (for example `vn.shopnexus.core.designsystem`).
- A feature module never depends on another feature module.
- `:core:model` and `:core:domain` are JVM modules with no Android dependency.
- material3 is pinned to `1.5.0-beta01` in the catalog and overrides the BOM; expressive APIs need `@OptIn(ExperimentalMaterial3ExpressiveApi::class)`.
- Colors only through the theme. `Color(0x…)` is allowed in `:core:designsystem` only; elsewhere only `Color.Black`, `Color.White`, `Color.Transparent`, `Color.Unspecified` (photo scrims and on-photo text).
- Type scale, exactly: displaySmall 36/44 400, headlineMedium 28/36 400, headlineSmall 24/32 400, titleLarge 22/28 400, titleMedium 16/24 500, titleSmall 14/20 500, bodyLarge 16/24 400, bodyMedium 14/20 400, bodySmall 12/16 400, labelLarge 14/20 500, labelMedium 12/16 500, labelSmall 11/16 500.
- Corner radii 4, 8, 12, 16, 20, 28, 32 dp. Touch targets ≥ 48 dp.
- Terracotta (`tertiary`, `tertiaryFixed` #FFDBCF, `onTertiaryFixedVariant` #773215) marks bargaining and price talk only.
- Every UI string is Vietnamese and lives in `strings.xml`; money sentences are keyed by `MoneyKey`.
- Money is `Vnd(amount: Long)`; displayed as `10.900.000 ₫` (dot thousands, non-breaking space before ₫) or short `10,9 tr`.
- Deal rules: COD up to 5.000.000 ₫; COD hand-over within 48 hours; offer floor is half the listed price rounded up to 100.000 ₫, ceiling below the counter, 100.000 ₫ steps; tiers Mới 0, Tin cậy 200, Uy tín 500, Xuất sắc 800; COD open-order caps 2 / 5 / 10 / 20 by tier; 90-day window, five-order minimum, buyer refusal rate 20 % → one open COD order, 35 % → no COD for 30 days, 30 clean days lift a step.
- A step involving money never shows as done before its command succeeds.
- Tests run on the JVM: `./gradlew check verifyRoborazziDebug` must pass at the end of every task that touches code.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Before writing prose that lands in a file (README, comments, commit messages), use the `humanizing-writing` skill and run `python3 ~/.claude/skills/humanizing-writing/ai-tells.py --stats FILE`.

## Review Focus

1. Offer amounts typed with separators, pasted, or cleared ("10.500.000", "10,5tr", ""): only the digits count; an empty or out-of-range amount disables "Gửi" and the line under the amount says why. Pinned in Task 5 (`OfferInputTest`), Task 14 (`AmountStepperTest`) and Task 20 (`typedAmountsKeepOnlyDigits`).
2. A command button tapped twice before the first call returns (Gửi, Đồng ý, Quét mã, Gửi ghi nhận): exactly one command goes out, and the buttons are disabled while it is pending. Pinned in Task 20 (`sendingTwiceSendsOnceAndRelabelsTheButton`), Task 21 (`doubleTapSendsOnce`) and Task 22 (`aPendingCommandDisablesTheConsole`).
3. Rotation or process death with an offer half-typed, a message half-written or a sheet open: the draft survives through `SavedStateHandle`; the deal comes back from the repository. Pinned in Task 20 (`theDraftSurvivesRecreation`) and Task 21 (`draftSurvivesRecreation`).
4. A failing money command (Đồng ý, Quét mã, Gửi): the console stays on its previous state, the snackbar says "Chưa gửi được. Thử lại", no milestone is drawn, and an optimistic price pill is taken back. Pinned in Task 21 (`failedHandoverIsNotShownAsDone`, `aFailedOfferRestoresTheEditorAndDropsThePill`) and Task 20 (`aFailedOfferKeepsTheSheetOpen`).
5. Long Vietnamese titles at font scale 1.3 in fixed-height rows and buttons (console buttons, listing cards, the top bar): text ellipsizes and nothing is cut off or overlaps. Pinned in the `font130` screenshots of Tasks 13–22 and the `textFitsAtFontScale130` tests (with `assertNoClippedText`) of Tasks 19, 20 and 22.

---

## File structure

```
app2/                                   repo root (git: shopnexus/app2)
  .superdesign/                         mockups, unchanged (tmp/ ignored except *.html)
  mohinh.md                             deal model
  README.md, .github/workflows/check.yml, tools/review_page.py
  settings.gradle.kts, build.gradle.kts, gradle.properties
  gradle/libs.versions.toml, gradle/wrapper/*, gradlew, gradlew.bat
  build-logic/convention/src/main/kotlin/
    Catalog.kt                          version-catalog helpers
    JvmLibraryConventionPlugin.kt       shopnexus.jvm.library
    AndroidLibraryConventionPlugin.kt   shopnexus.android.library (no Compose: data, navigation)
    AndroidLibraryComposeConventionPlugin.kt  shopnexus.android.library.compose (+ Robolectric, Roborazzi)
    AndroidFeatureConventionPlugin.kt   shopnexus.android.feature
    AndroidApplicationConventionPlugin.kt shopnexus.android.application
    HiltConventionPlugin.kt             shopnexus.hilt
    CheckNoRawColorsTask.kt             the raw-colour scan
  core/model/       Money.kt, MoneyFormat.kt, Ids, Time, Listing, Home, People, Deal, Thread, Commands, MoneyKey, Draft
  core/domain/      Handover, Offers, Reputation, Rights, Posting, MoneyNotes, DealConsole, RelativeTime
  core/data/        Repositories.kt, di/DataModule.kt, fake/ (Fixtures, FakeWorld, FailurePolicy, FakeDealEngine,
                    fake repositories, FakeQrScanner, Simulator, DebugControls), resources/fixtures/*.json
  core/testing/     SchedulerClock, MainDispatcherRule, Screenshots (variants, fake images), Clipping
  core/designsystem/ theme/ (Color, Type, Shape, Theme), icon/ (Symbols generated, SymbolIcon), component/*,
                    res/font, res/values/strings.xml, symbols.txt, tools/gen_symbols.py, src/test/screenshots
  core/navigation/  Routes.kt, Navigator.kt (Navigator, EntryInstaller), DeepLinks.kt
  feature/placeholder/ PlaceholderScreen, PlaceholderInstaller
  feature/discover/ home/ (HomeViewModel, HomeScreen, HomeTop, HeroCarousel, CategoryRow),
                    detail/ (ListingDetailViewModel, ListingDetailScreen, DetailSections, DetailSheets, PhotoViewer), DiscoverInstaller
  feature/deal/     chat/ (ChatUiState, ChatViewModel, ChatScreen, Thread, Console, Composer, Sheets, Scanner), DealInstaller
  app/              ShopNexusApplication, MainActivity, AppNavigation (tabs, back stacks, NavDisplay), ThemeSettings,
                    debug/DebugHost (the panel), release/DebugHost (pass-through)
```

Publishing the repository to GitHub and adding it to the umbrella as a submodule is not part of this plan; it happens after the user approves the result.


### Task 1: Toolchain and repository

The machine has no JDK, Android SDK or Gradle. This task installs them under the user's home directory, without root, and turns `app2/` into its own git repository.

**Files:**
- Create: `~/.local/share/shopnexus/android-env.sh`
- Create: `app2/.gitignore`
- Create: `app2/local.properties` (ignored by git)

- [ ] **Step 1: Install JDK 21 (Temurin) and Gradle 9.7.0**

```bash
mkdir -p ~/.local/opt ~/.local/share/shopnexus
cd ~/.local/opt
curl -L -o jdk21.tar.gz "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz"
tar xzf jdk21.tar.gz && rm jdk21.tar.gz && mv jdk-21.0.12.1+1 jdk-21
curl -L -o gradle.zip "https://services.gradle.org/distributions/gradle-9.7.0-bin.zip"
unzip -q gradle.zip && rm gradle.zip
```

- [ ] **Step 2: Install the Android command-line tools and SDK packages**

```bash
mkdir -p ~/Android/Sdk/cmdline-tools && cd ~/Android/Sdk/cmdline-tools
curl -L -o tools.zip "https://dl.google.com/android/repository/commandlinetools-linux-16111833_latest.zip"
unzip -q tools.zip && rm tools.zip && mv cmdline-tools latest
```

- [ ] **Step 3: Write the environment file**

`~/.local/share/shopnexus/android-env.sh`:

```bash
export JAVA_HOME="$HOME/.local/opt/jdk-21"
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$HOME/.local/opt/gradle-9.7.0/bin:$PATH"
```

Every later shell step starts with `source ~/.local/share/shopnexus/android-env.sh`.

- [ ] **Step 4: Accept licences and install the SDK packages**

```bash
source ~/.local/share/shopnexus/android-env.sh
yes | sdkmanager --licenses > /dev/null
sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.1.0"
```

- [ ] **Step 5: Verify the toolchain**

Run:
```bash
source ~/.local/share/shopnexus/android-env.sh
java -version 2>&1 | head -1
gradle --version | grep -E "^Gradle|^Kotlin"
sdkmanager --list_installed | grep -E "platforms;android-36 |build-tools;36.1.0|platform-tools"
```
Expected: `openjdk version "21.0.12"`, `Gradle 9.7.0`, and three installed packages.

- [ ] **Step 6: Install the emulator in the background (for walking the slice by hand in Task 24)**

```bash
source ~/.local/share/shopnexus/android-env.sh
sdkmanager "emulator" "system-images;android-36;google_apis;x86_64"
echo no | avdmanager create avd -n app2-api36 -k "system-images;android-36;google_apis;x86_64" -d pixel_8
```
Expected: `avdmanager list avd` lists `app2-api36`. This download is about 1.5 GB; later tasks do not wait for it.

- [ ] **Step 7: Make `app2/` a git repository**

`app2/.gitignore`:

```gitignore
.gradle/
build/
local.properties
.kotlin/
*.iml
.idea/
captures/
.superdesign/tmp/
```

`app2/local.properties`:

```properties
sdk.dir=/home/beanbocchi/Android/Sdk
```

```bash
cd /home/beanbocchi/shopnexus/app2
git init -b main
git add .gitignore mohinh.md .superdesign/design-system.md .superdesign/resume.json .superdesign/tools
git commit -m "chore: start the app2 repository with the mockups and the deal model

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
Expected: `git log --oneline` shows one commit; `git status` is clean; `.superdesign/tmp/` (screenshots, browser profile, 398 MB) is not tracked.

---

### Task 2: Gradle skeleton and the first module

The build uses an included build, `build-logic`, for convention plugins, a version catalog for every version, and the Gradle wrapper. This task proves the chain with one JVM module, `:core:model`, and its first type, `Vnd`.

**Files:**
- Create: `app2/settings.gradle.kts`, `app2/build.gradle.kts`, `app2/gradle.properties`, `app2/gradle/libs.versions.toml`
- Create: `app2/build-logic/settings.gradle.kts`, `app2/build-logic/convention/build.gradle.kts`
- Create: `app2/build-logic/convention/src/main/kotlin/Catalog.kt`
- Create: `app2/build-logic/convention/src/main/kotlin/JvmLibraryConventionPlugin.kt`
- Create: `app2/core/model/build.gradle.kts`
- Create: `app2/core/model/src/main/kotlin/vn/shopnexus/core/model/Money.kt`
- Test: `app2/core/model/src/test/kotlin/vn/shopnexus/core/model/VndTest.kt`

**Interfaces:**
- Produces: plugin id `shopnexus.jvm.library`; catalog aliases used by every later task (listed in the file below); `vn.shopnexus.core.model.Vnd`:
  ```kotlin
  @JvmInline @Serializable value class Vnd(val amount: Long) : Comparable<Vnd> {
      operator fun plus(other: Vnd): Vnd
      operator fun minus(other: Vnd): Vnd
      companion object { val ZERO: Vnd }
  }
  ```

- [ ] **Step 1: Write the version catalog**

`app2/gradle/libs.versions.toml`:

```toml
[versions]
agp = "9.4.1"
kotlin = "2.4.21"
ksp = "2.3.12"
composeBom = "2026.09.00"
material3 = "1.5.0-beta01"
navigation3 = "1.2.0"
lifecycle = "2.11.0"
activityCompose = "1.13.0"
coreKtx = "1.19.1"
datastore = "1.2.1"
hilt = "2.60.1"
hiltLifecycleCompose = "1.4.0"
coroutines = "1.11.0"
serialization = "1.11.0"
coil = "3.6.3"
junit = "4.13.2"
truth = "1.4.5"
turbine = "1.2.1"
robolectric = "4.17"
roborazzi = "1.76.0"
androidxTestCore = "1.7.0"
androidxTestExtJunit = "1.3.0"

[libraries]
android-gradlePlugin = { group = "com.android.tools.build", name = "gradle", version.ref = "agp" }
androidx-core-ktx = { group = "androidx.core", name = "core-ktx", version.ref = "coreKtx" }
androidx-activity-compose = { group = "androidx.activity", name = "activity-compose", version.ref = "activityCompose" }
androidx-compose-bom = { group = "androidx.compose", name = "compose-bom", version.ref = "composeBom" }
androidx-compose-ui = { group = "androidx.compose.ui", name = "ui" }
androidx-compose-foundation = { group = "androidx.compose.foundation", name = "foundation" }
androidx-compose-ui-tooling = { group = "androidx.compose.ui", name = "ui-tooling" }
androidx-compose-ui-tooling-preview = { group = "androidx.compose.ui", name = "ui-tooling-preview" }
androidx-compose-ui-test-junit4 = { group = "androidx.compose.ui", name = "ui-test-junit4" }
androidx-compose-ui-test-manifest = { group = "androidx.compose.ui", name = "ui-test-manifest" }
androidx-compose-material3 = { group = "androidx.compose.material3", name = "material3", version.ref = "material3" }
androidx-navigation3-runtime = { group = "androidx.navigation3", name = "navigation3-runtime", version.ref = "navigation3" }
androidx-navigation3-ui = { group = "androidx.navigation3", name = "navigation3-ui", version.ref = "navigation3" }
androidx-lifecycle-viewmodel-navigation3 = { group = "androidx.lifecycle", name = "lifecycle-viewmodel-navigation3", version.ref = "lifecycle" }
androidx-lifecycle-runtime-compose = { group = "androidx.lifecycle", name = "lifecycle-runtime-compose", version.ref = "lifecycle" }
androidx-lifecycle-viewmodel-compose = { group = "androidx.lifecycle", name = "lifecycle-viewmodel-compose", version.ref = "lifecycle" }
androidx-datastore-preferences = { group = "androidx.datastore", name = "datastore-preferences", version.ref = "datastore" }
hilt-android = { group = "com.google.dagger", name = "hilt-android", version.ref = "hilt" }
hilt-compiler = { group = "com.google.dagger", name = "hilt-compiler", version.ref = "hilt" }
hilt-android-testing = { group = "com.google.dagger", name = "hilt-android-testing", version.ref = "hilt" }
androidx-hilt-lifecycle-viewmodel-compose = { group = "androidx.hilt", name = "hilt-lifecycle-viewmodel-compose", version.ref = "hiltLifecycleCompose" }
kotlinx-coroutines-core = { group = "org.jetbrains.kotlinx", name = "kotlinx-coroutines-core", version.ref = "coroutines" }
kotlinx-coroutines-android = { group = "org.jetbrains.kotlinx", name = "kotlinx-coroutines-android", version.ref = "coroutines" }
kotlinx-coroutines-test = { group = "org.jetbrains.kotlinx", name = "kotlinx-coroutines-test", version.ref = "coroutines" }
kotlinx-serialization-json = { group = "org.jetbrains.kotlinx", name = "kotlinx-serialization-json", version.ref = "serialization" }
coil-compose = { group = "io.coil-kt.coil3", name = "coil-compose", version.ref = "coil" }
coil-network-okhttp = { group = "io.coil-kt.coil3", name = "coil-network-okhttp", version.ref = "coil" }
coil-test = { group = "io.coil-kt.coil3", name = "coil-test", version.ref = "coil" }
junit = { group = "junit", name = "junit", version.ref = "junit" }
truth = { group = "com.google.truth", name = "truth", version.ref = "truth" }
turbine = { group = "app.cash.turbine", name = "turbine", version.ref = "turbine" }
robolectric = { group = "org.robolectric", name = "robolectric", version.ref = "robolectric" }
roborazzi = { group = "io.github.takahirom.roborazzi", name = "roborazzi", version.ref = "roborazzi" }
roborazzi-compose = { group = "io.github.takahirom.roborazzi", name = "roborazzi-compose", version.ref = "roborazzi" }
roborazzi-junit-rule = { group = "io.github.takahirom.roborazzi", name = "roborazzi-junit-rule", version.ref = "roborazzi" }
androidx-test-core = { group = "androidx.test", name = "core", version.ref = "androidxTestCore" }
androidx-test-ext-junit = { group = "androidx.test.ext", name = "junit", version.ref = "androidxTestExtJunit" }

[plugins]
android-application = { id = "com.android.application", version.ref = "agp" }
android-library = { id = "com.android.library", version.ref = "agp" }
kotlin-jvm = { id = "org.jetbrains.kotlin.jvm", version.ref = "kotlin" }
kotlin-serialization = { id = "org.jetbrains.kotlin.plugin.serialization", version.ref = "kotlin" }
compose = { id = "org.jetbrains.kotlin.plugin.compose", version.ref = "kotlin" }
ksp = { id = "com.google.devtools.ksp", version.ref = "ksp" }
hilt = { id = "com.google.dagger.hilt.android", version.ref = "hilt" }
roborazzi = { id = "io.github.takahirom.roborazzi", version.ref = "roborazzi" }
```

- [ ] **Step 2: Write the root build files**

`app2/settings.gradle.kts`:

```kotlin
pluginManagement {
    includeBuild("build-logic")
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "shopnexus-app2"

include(":core:model")
```

`app2/build.gradle.kts`, which puts every plugin on the classpath so the convention plugins can apply them by id:

```kotlin
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.compose) apply false
    alias(libs.plugins.ksp) apply false
    alias(libs.plugins.hilt) apply false
    alias(libs.plugins.roborazzi) apply false
}
```

`app2/gradle.properties`:

```properties
org.gradle.jvmargs=-Xmx4g -Dfile.encoding=UTF-8
org.gradle.parallel=true
org.gradle.caching=true
org.gradle.configuration-cache=true
android.useAndroidX=true
android.nonTransitiveRClass=true
kotlin.code.style=official
```

- [ ] **Step 3: Write the included build**

`app2/build-logic/settings.gradle.kts`:

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
    versionCatalogs {
        create("libs") { from(files("../gradle/libs.versions.toml")) }
    }
}

rootProject.name = "build-logic"
include(":convention")
```

`app2/build-logic/convention/build.gradle.kts`. Only AGP is a compile-time dependency; Kotlin plugins are applied by id, so build-logic never compiles against the Kotlin Gradle plugin and its metadata version:

```kotlin
plugins {
    `kotlin-dsl`
}

group = "vn.shopnexus.buildlogic"

dependencies {
    compileOnly(libs.android.gradlePlugin)
}

gradlePlugin {
    plugins {
        register("jvmLibrary") {
            id = "shopnexus.jvm.library"
            implementationClass = "JvmLibraryConventionPlugin"
        }
    }
}
```

`app2/build-logic/convention/src/main/kotlin/Catalog.kt`:

```kotlin
import org.gradle.api.Project
import org.gradle.api.artifacts.MinimalExternalModuleDependency
import org.gradle.api.artifacts.VersionCatalog
import org.gradle.api.artifacts.VersionCatalogsExtension
import org.gradle.api.provider.Provider
import org.gradle.kotlin.dsl.getByType

internal val Project.libs: VersionCatalog
    get() = extensions.getByType<VersionCatalogsExtension>().named("libs")

internal fun VersionCatalog.library(alias: String): Provider<MinimalExternalModuleDependency> =
    findLibrary(alias).orElseThrow { IllegalArgumentException("No library '$alias' in libs.versions.toml") }
```

`app2/build-logic/convention/src/main/kotlin/JvmLibraryConventionPlugin.kt`:

```kotlin
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.plugins.JavaPluginExtension
import org.gradle.jvm.toolchain.JavaLanguageVersion
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.dependencies

/** Plain Kotlin modules (`:core:model`, `:core:domain`): no Android, JDK 21, kotlinx.serialization. */
class JvmLibraryConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("org.jetbrains.kotlin.jvm")
        pluginManager.apply("org.jetbrains.kotlin.plugin.serialization")
        extensions.configure<JavaPluginExtension> {
            toolchain.languageVersion.set(JavaLanguageVersion.of(21))
        }
        dependencies {
            add("implementation", libs.library("kotlinx-serialization-json"))
            add("testImplementation", libs.library("junit"))
            add("testImplementation", libs.library("truth"))
        }
    }
}
```

- [ ] **Step 4: Generate the Gradle wrapper**

```bash
source ~/.local/share/shopnexus/android-env.sh
cd /home/beanbocchi/shopnexus/app2
gradle wrapper --gradle-version 9.7.0 --distribution-type bin
./gradlew --version | grep -E "^Gradle|^Kotlin"
```
Expected: `Gradle 9.7.0`. From here on, use `./gradlew` only.

- [ ] **Step 5: Write the failing test**

`app2/core/model/build.gradle.kts`:

```kotlin
plugins {
    id("shopnexus.jvm.library")
}
```

`app2/core/model/src/test/kotlin/vn/shopnexus/core/model/VndTest.kt`:

```kotlin
package vn.shopnexus.core.model

import com.google.common.truth.Truth.assertThat
import kotlinx.serialization.json.Json
import org.junit.Test

class VndTest {
    @Test
    fun addsSubtractsAndCompares() {
        assertThat(Vnd(10_900_000) - Vnd(300_000)).isEqualTo(Vnd(10_600_000))
        assertThat(Vnd(5_000_000) + Vnd.ZERO).isEqualTo(Vnd(5_000_000))
        assertThat(Vnd(5_000_000) <= Vnd(5_000_000)).isTrue()
        assertThat(Vnd(5_000_001) > Vnd(5_000_000)).isTrue()
    }

    @Test
    fun serializesAsAPlainNumber() {
        assertThat(Json.encodeToString(Vnd.serializer(), Vnd(350_000))).isEqualTo("350000")
        assertThat(Json.decodeFromString(Vnd.serializer(), "350000")).isEqualTo(Vnd(350_000))
    }
}
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `./gradlew :core:model:test`
Expected: FAIL, compilation error `Unresolved reference 'Vnd'`.

- [ ] **Step 7: Write the minimal implementation**

`app2/core/model/src/main/kotlin/vn/shopnexus/core/model/Money.kt`:

```kotlin
package vn.shopnexus.core.model

import kotlinx.serialization.Serializable

/** An amount in Vietnamese đồng. The đồng has no subunit, so a Long holds it exactly. */
@JvmInline
@Serializable
value class Vnd(val amount: Long) : Comparable<Vnd> {
    operator fun plus(other: Vnd): Vnd = Vnd(amount + other.amount)
    operator fun minus(other: Vnd): Vnd = Vnd(amount - other.amount)
    override fun compareTo(other: Vnd): Int = amount.compareTo(other.amount)

    companion object {
        val ZERO = Vnd(0)
    }
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `./gradlew :core:model:test`
Expected: PASS, 2 tests.

- [ ] **Step 9: Commit**

```bash
git add settings.gradle.kts build.gradle.kts gradle.properties gradle gradlew gradlew.bat build-logic core/model
git commit -m "build: add the Gradle skeleton, build-logic and the core:model module

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The domain types (`:core:model`)

Every type the screens, the rules and the fakes share, all `@Serializable`, with a JSON round trip test. Times are `java.time.Instant`, written as ISO-8601 strings.

**Files:**
- Create in `app2/core/model/src/main/kotlin/vn/shopnexus/core/model/`: `Ids.kt`, `Time.kt`, `Listing.kt`, `Home.kt`, `People.kt`, `Deal.kt`, `Thread.kt`, `Commands.kt`, `MoneyKey.kt`, `Draft.kt`
- Test: `app2/core/model/src/test/kotlin/vn/shopnexus/core/model/SerializationTest.kt`

**Interfaces:**
- Consumes: `Vnd` (Task 2).
- Produces (exact names used by every later task):
  - Ids: `ListingId`, `UserId`, `DealId`, `RecordId` (value classes over `String`).
  - `Moment` = `@Serializable(InstantIsoSerializer::class) Instant`; `ShopNexusJson: Json` (ignores unknown keys, class discriminator `type`).
  - Listing: `Condition { NEW, LIKE_NEW, USED }`, `HandoverPath { MEET, COD }`, `PhotoSource { APP, LIBRARY }`, `Photo(url, source, capturedAt: Moment?, alt)`, `DeclaredMark(text, closeUp: Photo)`, `Spec(label, value)`, `PriceDirection { CHEAPER, PRICIER }`, `PriceRange(low, median, high: Vnd)`, `PriceInsight(direction, percent: Int, range: PriceRange? = null, sampleSize: Int? = null, windowDays: Int? = null, area: String? = null)`, `Listing(...)`, `ListingSummary(id, photoUrl, price, title, condition, distanceKm: Double, insight: PriceInsight? = null, saved: Boolean = false)`.
  - Home: `HeroSlide(imageUrl, tag, title, cta)`, `CategoryEntry(key, label, icon, shape)`, `HomeFeed(district, searchHints, hero, categories, nearby, interests, forYou, unreadNotifications)`.
  - People: `Tier { NEW, TRUSTED, REPUTABLE, TOP }`, `SellerSummary(id, name, avatarUrl, verified, tier, rating: Double, ratingCount, sold, replyTime, joinedYear)`, `Me(id, name, avatarUrl, district)`, `PublicProfile(seller: SellerSummary, publicRecords: List<IncidentRecord>)`, `MyReputation(score: Int, tier: Tier, codOpenCap: Int, listingCap: Int, codBlockedUntil: Moment?, codOrders90: Int, codRefused90: Int)`; the last two are defined now and first used in stage 5.
  - Detail: `ListingDetail(listing, seller, insight: PriceInsight?, similar: List<ListingSummary>, saved, questions: List<String>, suggestedOffers: List<Vnd>, deal: DealRef? = null)`; `DealRef(id: DealId, counter: Vnd?, myOffer: Vnd? = null)` is the buyer's open deal on this listing, so Listing detail and Chat share one offer range and Listing detail can say "Đã trả 10,4 tr"; `ReportReason { BANNED, FAKE, SCAM, OTHER }`.
  - Deal: `Party { BUYER, SELLER }`, `OfferStatus { OPEN, ACCEPTED, WITHDRAWN, SUPERSEDED }`, `Offer(by, amount, at, status)`, `MeetPoint(name, why)`, `Meeting(at: Moment, place: MeetPoint, proposedBy: Party, confirmed: Boolean)`, `CheckItem(id, text, icon, checked)`, `DealStage { NEGOTIATE, ARRANGE, HANDOVER, RATE, DONE }`, `CarrierEvent(text, at)`, `CodShipment(fee, deadline: Moment, events)`, `RecordStatus { OPEN, REFUNDED, DECLINED, WITHDRAWN }`, `IncidentRecord(id, by, photoUrl, text, aiNote, status, refund: Vnd? = null, refundConfirmed: Boolean = false, public: Boolean = true)`, `Deal(...)` (fields below), `ChatView(deal, listing: ListingSummary, counterpart: SellerSummary, me: Me, declaredMarks: List<DeclaredMark>)`.
  - Thread: `sealed interface ThreadItem { val at: Instant }` with `Text(by, text, at)`, `Photos(by, urls, at)`, `PriceMove(by, amount, accepted, at)`, `Event(icon, text, at)`, `Milestone(kind: MilestoneKind, at)`, `Record(recordId, at)`; `MilestoneKind { AGREED, HANDED_OVER, RATED }`.
  - Commands: `sealed interface DealCommand` with `SendText(text)`, `SendOffer(amount, note: String?)`, `AcceptCounter`, `WithdrawOffer`, `ProposeMeeting(at: Moment, place)`, `ConfirmMeeting`, `SetCheck(itemId, checked)`, `RecordHandover(code)`, `Rate(stars: Int)`, `OpenRecord(photoUrl, text)`, `ConfirmRefund(recordId)`.
  - `MoneyKey { MEET, OVER_LIMIT, NO_HOLD, AFTER_PAY, DECLARED, COD_BUYER, REFUSE, HANDOVER, COD_SELLER, RETURN_LEG }`.
  - Drafts: `MarkDecision { PENDING, DECLARED, DISMISSED }`, `AiMark(text, decision)`, `ListingDraft(title, price: Vnd?, paths: Set<HandoverPath>, aiMarks: List<AiMark>)`.

- [ ] **Step 1: Write the failing round-trip test**

`app2/core/model/src/test/kotlin/vn/shopnexus/core/model/SerializationTest.kt`:

```kotlin
package vn.shopnexus.core.model

import com.google.common.truth.Truth.assertThat
import java.time.Instant
import org.junit.Test

class SerializationTest {
    private val at = Instant.parse("2026-10-15T07:10:00Z")

    @Test
    fun dealRoundTripsWithEveryThreadItem() {
        val deal = Deal(
            id = DealId("d-kiet"), listingId = ListingId("p-iphone13"),
            buyerId = UserId("u-linh"), sellerId = UserId("u-kiet"),
            listedPrice = Vnd(10_900_000), path = HandoverPath.MEET, stage = DealStage.NEGOTIATE,
            offers = listOf(Offer(Party.SELLER, Vnd(10_600_000), at, OfferStatus.OPEN)),
            meeting = Meeting(at, MeetPoint("Sảnh Landmark 81", "Có bảo vệ, đông người"), Party.SELLER, confirmed = false),
            checklist = listOf(CheckItem("k0", "Face ID mở được máy", "familiar_face_and_zone", false)),
            records = listOf(IncidentRecord(RecordId("r1"), Party.BUYER, "https://x/p.jpg", "Vết nứt", "Tin không khai", RecordStatus.OPEN)),
            thread = listOf(
                ThreadItem.Text(Party.BUYER, "Chào bạn", at),
                ThreadItem.Photos(Party.SELLER, listOf("https://x/1.jpg"), at),
                ThreadItem.PriceMove(Party.SELLER, Vnd(10_600_000), accepted = false, at = at),
                ThreadItem.Event("event_available", "Đã hẹn 19:00 hôm nay", at),
                ThreadItem.Milestone(MilestoneKind.AGREED, at),
                ThreadItem.Record(RecordId("r1"), at),
            ),
            counterExpiresAt = Instant.parse("2026-10-16T07:10:00Z"),
        )
        val text = ShopNexusJson.encodeToString(Deal.serializer(), deal)
        assertThat(text).contains("\"type\":\"priceMove\"")
        assertThat(text).contains("\"at\":\"2026-10-15T07:10:00Z\"")
        assertThat(ShopNexusJson.decodeFromString(Deal.serializer(), text)).isEqualTo(deal)
    }

    @Test
    fun commandsCarryTheirKind() {
        val text = ShopNexusJson.encodeToString(DealCommand.serializer(), DealCommand.SendOffer(Vnd(10_500_000), null))
        assertThat(text).isEqualTo("{\"type\":\"sendOffer\",\"amount\":10500000,\"note\":null}")
        assertThat(ShopNexusJson.decodeFromString(DealCommand.serializer(), "{\"type\":\"acceptCounter\"}"))
            .isEqualTo(DealCommand.AcceptCounter)
    }

    @Test
    fun unknownFieldsFromTheServerAreIgnored() {
        val summary = ShopNexusJson.decodeFromString(
            ListingSummary.serializer(),
            """{"id":"l-1","photoUrl":"u","price":1,"title":"t","condition":"USED","distanceKm":0.6,"badge":"new"}""",
        )
        assertThat(summary.id).isEqualTo(ListingId("l-1"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./gradlew :core:model:test --tests "*SerializationTest*"`
Expected: FAIL, unresolved references (`Deal`, `ShopNexusJson`, …).

- [ ] **Step 3: Write the types**

`Ids.kt`:

```kotlin
package vn.shopnexus.core.model

import kotlinx.serialization.Serializable

@JvmInline @Serializable value class ListingId(val value: String)
@JvmInline @Serializable value class UserId(val value: String)
@JvmInline @Serializable value class DealId(val value: String)
@JvmInline @Serializable value class RecordId(val value: String)
```

`Time.kt`:

```kotlin
package vn.shopnexus.core.model

import java.time.Instant
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json

object InstantIsoSerializer : KSerializer<Instant> {
    override val descriptor = PrimitiveSerialDescriptor("vn.shopnexus.Instant", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: Instant) = encoder.encodeString(value.toString())
    override fun deserialize(decoder: Decoder): Instant = Instant.parse(decoder.decodeString())
}

/** A point in time on the wire: an ISO-8601 instant in UTC. */
typealias Moment = @Serializable(with = InstantIsoSerializer::class) Instant

/** The one Json configuration for fixtures and, later, the network. */
val ShopNexusJson: Json = Json {
    ignoreUnknownKeys = true
    classDiscriminator = "type"
    explicitNulls = true
}
```

`Listing.kt`:

```kotlin
package vn.shopnexus.core.model

import kotlinx.serialization.Serializable

@Serializable enum class Condition { NEW, LIKE_NEW, USED }
@Serializable enum class HandoverPath { MEET, COD }
@Serializable enum class PhotoSource { APP, LIBRARY }

/** A listing photo. Photos taken in the app carry their capture time, the anti-swap fingerprint. */
@Serializable
data class Photo(val url: String, val source: PhotoSource, val capturedAt: Moment? = null, val alt: String = "")

/** A visible mark the seller declared, with a close-up. A declared mark cannot be a reason for a complaint. */
@Serializable
data class DeclaredMark(val text: String, val closeUp: Photo)

@Serializable
data class Spec(val label: String, val value: String)

@Serializable enum class PriceDirection { CHEAPER, PRICIER }

@Serializable
data class PriceRange(val low: Vnd, val median: Vnd, val high: Vnd)

/** The model's price judgment. Cards carry the percent only; Listing detail carries how it was made. */
@Serializable
data class PriceInsight(
    val direction: PriceDirection,
    val percent: Int,
    val range: PriceRange? = null,
    val sampleSize: Int? = null,
    val windowDays: Int? = null,
    val area: String? = null,
)

@Serializable
data class Listing(
    val id: ListingId,
    val sellerId: UserId,
    val title: String,
    val price: Vnd,
    val categoryPath: List<String>,
    val condition: Condition,
    val declaredMarks: List<DeclaredMark>,
    val photos: List<Photo>,
    val specs: List<Spec>,
    val description: String,
    val district: String,
    val distanceKm: Double,
    val paths: Set<HandoverPath>,
    val allowOffers: Boolean,
    val postedAt: Moment,
    val meetNote: String,
)

/** The fields a listing card shows; feeds and rails carry only these. */
@Serializable
data class ListingSummary(
    val id: ListingId,
    val photoUrl: String,
    val price: Vnd,
    val title: String,
    val condition: Condition,
    val distanceKm: Double,
    val insight: PriceInsight? = null,
    val saved: Boolean = false,
)
```

`Home.kt`:

```kotlin
package vn.shopnexus.core.model

import kotlinx.serialization.Serializable

@Serializable
data class HeroSlide(val imageUrl: String, val tag: String, val title: String, val cta: String)

/** `icon` is a Material Symbols name, `shape` a MaterialShapes name (Cookie9Sided, Clover4Leaf, …). */
@Serializable
data class CategoryEntry(val key: String, val label: String, val icon: String, val shape: String)

/** Everything Home shows, in one read. */
@Serializable
data class HomeFeed(
    val district: String,
    val searchHints: List<String>,
    val hero: List<HeroSlide>,
    val categories: List<CategoryEntry>,
    val nearby: List<ListingSummary>,
    val interests: List<String>,
    val forYou: List<ListingSummary>,
    val unreadNotifications: Int,
)

/** Everything Listing detail shows, in one read. */
@Serializable
data class ListingDetail(
    val listing: Listing,
    val seller: SellerSummary,
    val insight: PriceInsight?,
    val similar: List<ListingSummary>,
    val saved: Boolean,
    val questions: List<String>,
    val suggestedOffers: List<Vnd>,
    val deal: DealRef? = null,
)

/** The buyer's open deal on a listing: the seller's current counter and the buyer's own open offer, if any. */
@Serializable
data class DealRef(val id: DealId, val counter: Vnd?, val myOffer: Vnd? = null)

/** "Báo cáo tin": banned goods, fakes and fraud go to a person; condition and price stay between buyer and seller. */
@Serializable enum class ReportReason { BANNED, FAKE, SCAM, OTHER }
```

`People.kt`:

```kotlin
package vn.shopnexus.core.model

import kotlinx.serialization.Serializable

@Serializable enum class Tier { NEW, TRUSTED, REPUTABLE, TOP }

/** What anyone may see about a seller. The score itself is private to its owner. */
@Serializable
data class SellerSummary(
    val id: UserId,
    val name: String,
    val avatarUrl: String?,
    val verified: Boolean,
    val tier: Tier,
    val rating: Double,
    val ratingCount: Int,
    val sold: Int,
    val replyTime: String,
    val joinedYear: Int,
)

@Serializable
data class Me(val id: UserId, val name: String, val avatarUrl: String?, val district: String)

/** What other people may see about a seller: the summary and the records they chose to keep public. */
@Serializable
data class PublicProfile(val seller: SellerSummary, val publicRecords: List<IncidentRecord>)

/** The owner's own view of their reputation: the score, the rights in use and the 90-day numbers behind them. */
@Serializable
data class MyReputation(
    val score: Int,
    val tier: Tier,
    val codOpenCap: Int,
    val listingCap: Int,
    val codBlockedUntil: Moment?,
    val codOrders90: Int,
    val codRefused90: Int,
)
```

`Deal.kt`:

```kotlin
package vn.shopnexus.core.model

import kotlinx.serialization.Serializable

@Serializable enum class Party { BUYER, SELLER }
@Serializable enum class OfferStatus { OPEN, ACCEPTED, WITHDRAWN, SUPERSEDED }

@Serializable
data class Offer(val by: Party, val amount: Vnd, val at: Moment, val status: OfferStatus)

/** A suggested public meeting point and why it is safe. */
@Serializable
data class MeetPoint(val name: String, val why: String)

@Serializable
data class Meeting(val at: Moment, val place: MeetPoint, val proposedBy: Party, val confirmed: Boolean)

/** `icon` is a Material Symbols name. */
@Serializable
data class CheckItem(val id: String, val text: String, val icon: String, val checked: Boolean)

/**
 * The four phases of a deal, shared by both ways to hand over. In person:
 * Thương lượng, Hẹn gặp, Gặp và kiểm, Đánh giá. By COD: Thương lượng, Gửi
 * hàng, Xem và nhận, Đánh giá.
 */
@Serializable enum class DealStage { NEGOTIATE, ARRANGE, HANDOVER, RATE, DONE }

@Serializable
data class CarrierEvent(val text: String, val at: Moment)

@Serializable
data class CodShipment(val fee: Vnd, val deadline: Moment, val events: List<CarrierEvent>)

@Serializable enum class RecordStatus { OPEN, REFUNDED, DECLINED, WITHDRAWN }

/** A problem after the hand-over. ShopNexus records it and does not rule on it. */
@Serializable
data class IncidentRecord(
    val id: RecordId,
    val by: Party,
    val photoUrl: String,
    val text: String,
    val aiNote: String,
    val status: RecordStatus,
    val refund: Vnd? = null,
    val refundConfirmed: Boolean = false,
    /** Records are public by default; the seller can reply on a public record (stage 5). */
    val public: Boolean = true,
)

@Serializable
data class Deal(
    val id: DealId,
    val listingId: ListingId,
    val buyerId: UserId,
    val sellerId: UserId,
    val listedPrice: Vnd,
    val path: HandoverPath,
    val stage: DealStage,
    val offers: List<Offer> = emptyList(),
    val agreedPrice: Vnd? = null,
    val meeting: Meeting? = null,
    val meetPoints: List<MeetPoint> = emptyList(),
    val checklist: List<CheckItem> = emptyList(),
    val handedOverAt: Moment? = null,
    val rating: Int? = null,
    val records: List<IncidentRecord> = emptyList(),
    val thread: List<ThreadItem> = emptyList(),
    val cod: CodShipment? = null,
    /** The model's judgment of the seller's counter ("Rẻ hơn 15%"). */
    val priceInsight: PriceInsight? = null,
    /** When the seller's open counter stops binding. */
    val counterExpiresAt: Moment? = null,
) {
    val openCounter: Offer? get() = offers.lastOrNull { it.by == Party.SELLER && it.status == OfferStatus.OPEN }
    val openOffer: Offer? get() = offers.lastOrNull { it.by == Party.BUYER && it.status == OfferStatus.OPEN }
}

/** Everything Chat shows, in one read. */
@Serializable
data class ChatView(
    val deal: Deal,
    val listing: ListingSummary,
    val counterpart: SellerSummary,
    val me: Me,
    val declaredMarks: List<DeclaredMark>,
)
```

`Thread.kt`:

```kotlin
package vn.shopnexus.core.model

import java.time.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable enum class MilestoneKind { AGREED, HANDED_OVER, RATED }

/** One item of a deal's chat thread, in order. */
@Serializable
sealed interface ThreadItem {
    val at: Instant

    @Serializable @SerialName("text")
    data class Text(val by: Party, val text: String, override val at: Moment) : ThreadItem

    @Serializable @SerialName("photos")
    data class Photos(val by: Party, val urls: List<String>, override val at: Moment) : ThreadItem

    @Serializable @SerialName("priceMove")
    data class PriceMove(val by: Party, val amount: Vnd, val accepted: Boolean, override val at: Moment) : ThreadItem

    @Serializable @SerialName("event")
    data class Event(val icon: String, val text: String, override val at: Moment) : ThreadItem

    @Serializable @SerialName("milestone")
    data class Milestone(val kind: MilestoneKind, override val at: Moment) : ThreadItem

    @Serializable @SerialName("record")
    data class Record(val recordId: RecordId, override val at: Moment) : ThreadItem
}
```

`Commands.kt`:

```kotlin
package vn.shopnexus.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** What the buyer can do to a deal. Each command returns the updated Deal. */
@Serializable
sealed interface DealCommand {
    @Serializable @SerialName("sendText") data class SendText(val text: String) : DealCommand
    @Serializable @SerialName("sendOffer") data class SendOffer(val amount: Vnd, val note: String?) : DealCommand
    @Serializable @SerialName("acceptCounter") data object AcceptCounter : DealCommand
    @Serializable @SerialName("withdrawOffer") data object WithdrawOffer : DealCommand
    @Serializable @SerialName("proposeMeeting") data class ProposeMeeting(val at: Moment, val place: MeetPoint) : DealCommand
    @Serializable @SerialName("confirmMeeting") data object ConfirmMeeting : DealCommand
    @Serializable @SerialName("setCheck") data class SetCheck(val itemId: String, val checked: Boolean) : DealCommand
    @Serializable @SerialName("recordHandover") data class RecordHandover(val code: String) : DealCommand
    @Serializable @SerialName("rate") data class Rate(val stars: Int) : DealCommand
    @Serializable @SerialName("openRecord") data class OpenRecord(val photoUrl: String, val text: String) : DealCommand
    @Serializable @SerialName("confirmRefund") data class ConfirmRefund(val recordId: RecordId) : DealCommand
}
```

`MoneyKey.kt`:

```kotlin
package vn.shopnexus.core.model

/** One plain sentence per step that touches money; the words live in `:core:designsystem` strings. */
enum class MoneyKey { MEET, OVER_LIMIT, NO_HOLD, AFTER_PAY, DECLARED, COD_BUYER, REFUSE, HANDOVER, COD_SELLER, RETURN_LEG }
```

`Draft.kt`:

```kotlin
package vn.shopnexus.core.model

import kotlinx.serialization.Serializable

@Serializable enum class MarkDecision { PENDING, DECLARED, DISMISSED }

/** A mark the model saw in the photos; the seller declares or dismisses it. */
@Serializable
data class AiMark(val text: String, val decision: MarkDecision)

@Serializable
data class ListingDraft(
    val title: String,
    val price: Vnd?,
    val paths: Set<HandoverPath>,
    val aiMarks: List<AiMark>,
)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./gradlew :core:model:test`
Expected: PASS, 5 tests. If the `Moment` typealias is rejected by the serialization plugin (error mentioning "annotated typealias"), replace each `Moment` property with `@Serializable(with = InstantIsoSerializer::class) val at: Instant` and keep the test unchanged.

- [ ] **Step 5: Commit**

```bash
git add core/model
git commit -m "feat(model): add the domain types that form the API contract

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```


---

### Task 4: Hand-over rules (`:core:domain`)

COD limit, the 48-hour window, and what refusing at the door costs.

**Files:**
- Modify: `app2/settings.gradle.kts` (add `include(":core:domain")`)
- Create: `app2/core/domain/build.gradle.kts`
- Create: `app2/core/domain/src/main/kotlin/vn/shopnexus/core/domain/Handover.kt`
- Test: `app2/core/domain/src/test/kotlin/vn/shopnexus/core/domain/HandoverTest.kt`

**Interfaces:**
- Consumes: `Vnd`, `HandoverPath` (Task 3).
- Produces:
  ```kotlin
  val COD_LIMIT: Vnd                     // Vnd(5_000_000)
  val HANDOVER_WINDOW: java.time.Duration // 48 hours
  fun codAllowed(price: Vnd): Boolean
  fun availablePaths(offered: Set<HandoverPath>, price: Vnd): Set<HandoverPath>
  fun handoverDeadline(placedAt: Instant): Instant
  fun shippingRefundDue(placedAt: Instant, handedOverAt: Instant?, now: Instant): Boolean
  data class RefusalCost(val buyerLoses: Vnd, val sellerPays: Vnd)
  fun refusalCost(outboundFee: Vnd, returnLegFee: Vnd): RefusalCost
  ```

- [ ] **Step 1: Create the module**

`app2/core/domain/build.gradle.kts`:

```kotlin
plugins {
    id("shopnexus.jvm.library")
}

dependencies {
    api(project(":core:model"))
}
```

Add `include(":core:domain")` to `app2/settings.gradle.kts`.

- [ ] **Step 2: Write the failing test**

`app2/core/domain/src/test/kotlin/vn/shopnexus/core/domain/HandoverTest.kt`:

```kotlin
package vn.shopnexus.core.domain

import com.google.common.truth.Truth.assertThat
import java.time.Duration
import java.time.Instant
import org.junit.Test
import vn.shopnexus.core.model.HandoverPath
import vn.shopnexus.core.model.Vnd

class HandoverTest {
    private val placed = Instant.parse("2026-10-14T13:15:00Z")

    @Test
    fun codStopsAtFiveMillion() {
        assertThat(codAllowed(Vnd(5_000_000))).isTrue()
        assertThat(codAllowed(Vnd(5_000_001))).isFalse()
        assertThat(codAllowed(Vnd(10_900_000))).isFalse()
    }

    @Test
    fun aboveTheLimitOnlyMeetingRemains() {
        val both = setOf(HandoverPath.MEET, HandoverPath.COD)
        assertThat(availablePaths(both, Vnd(3_800_000))).isEqualTo(both)
        assertThat(availablePaths(both, Vnd(10_900_000))).containsExactly(HandoverPath.MEET)
    }

    @Test
    fun theSellerHasFortyEightHours() {
        assertThat(handoverDeadline(placed)).isEqualTo(placed.plus(Duration.ofHours(48)))
    }

    @Test
    fun shippingIsRefundedOnlyWhenTheWindowPassesWithoutAHandOver() {
        val deadline = handoverDeadline(placed)
        assertThat(shippingRefundDue(placed, handedOverAt = null, now = deadline.minusSeconds(1))).isFalse()
        assertThat(shippingRefundDue(placed, handedOverAt = null, now = deadline)).isTrue()
        assertThat(shippingRefundDue(placed, handedOverAt = placed.plusSeconds(3600), now = deadline.plusSeconds(1))).isFalse()
    }

    @Test
    fun refusingCostsTheBuyerTheOutboundLegAndTheSellerTheReturnLeg() {
        assertThat(refusalCost(Vnd(22_000), Vnd(22_000))).isEqualTo(RefusalCost(Vnd(22_000), Vnd(22_000)))
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `./gradlew :core:domain:test --tests "*HandoverTest*"`
Expected: FAIL, `Unresolved reference 'codAllowed'`.

- [ ] **Step 4: Write the implementation**

`app2/core/domain/src/main/kotlin/vn/shopnexus/core/domain/Handover.kt`:

```kotlin
package vn.shopnexus.core.domain

import java.time.Duration
import java.time.Instant
import vn.shopnexus.core.model.HandoverPath
import vn.shopnexus.core.model.Vnd

/** COD carries goods up to this price; above it the deal is in person only. */
val COD_LIMIT = Vnd(5_000_000)

/** How long a seller has to hand a COD parcel to the carrier. */
val HANDOVER_WINDOW: Duration = Duration.ofHours(48)

fun codAllowed(price: Vnd): Boolean = price <= COD_LIMIT

fun availablePaths(offered: Set<HandoverPath>, price: Vnd): Set<HandoverPath> =
    if (codAllowed(price)) offered else offered - HandoverPath.COD

fun handoverDeadline(placedAt: Instant): Instant = placedAt.plus(HANDOVER_WINDOW)

/** The buyer's prepaid shipping comes back by itself when the seller misses the window. */
fun shippingRefundDue(placedAt: Instant, handedOverAt: Instant?, now: Instant): Boolean =
    handedOverAt == null && !now.isBefore(handoverDeadline(placedAt))

data class RefusalCost(val buyerLoses: Vnd, val sellerPays: Vnd)

/** Refusing at the door is the refund: the buyer loses the outbound shipping, the seller pays the return leg. */
fun refusalCost(outboundFee: Vnd, returnLegFee: Vnd): RefusalCost = RefusalCost(outboundFee, returnLegFee)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./gradlew :core:domain:test`
Expected: PASS, 5 tests.

- [ ] **Step 6: Commit**

```bash
git add settings.gradle.kts core/domain
git commit -m "feat(domain): add the COD limit, the hand-over window and the refusal cost

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Offer range and offer input (`:core:domain`)

The amount control in the offer sheet and the chat console: the floor, the ceiling, the step, and how typed text becomes an amount.

**Files:**
- Create: `app2/core/domain/src/main/kotlin/vn/shopnexus/core/domain/Offers.kt`
- Test: `app2/core/domain/src/test/kotlin/vn/shopnexus/core/domain/OfferRangeTest.kt`
- Test: `app2/core/domain/src/test/kotlin/vn/shopnexus/core/domain/OfferInputTest.kt`

**Interfaces:**
- Produces:
  ```kotlin
  val OFFER_STEP: Vnd                                    // Vnd(100_000)
  data class OfferRange(val floor: Vnd, val ceiling: Vnd, val step: Vnd) {
      val highest: Vnd                                   // largest multiple of step below ceiling
      fun stepped(from: Vnd, up: Boolean): Vnd           // clamped to floor..highest
      fun check(amount: Vnd?): OfferCheck
  }
  sealed interface OfferCheck {
      data object Empty : OfferCheck
      data class TooLow(val floor: Vnd) : OfferCheck
      data class NotBelow(val ceiling: Vnd) : OfferCheck
      data class Ok(val gap: Vnd) : OfferCheck          // ceiling - amount
  }
  fun offerRange(listed: Vnd, counter: Vnd?): OfferRange
  fun parseOfferInput(text: String): Vnd?
  ```

The mockup's Listing detail sheet says "Từ 5.450.000 ₫ trở lên" while its chat console steps from 5.500.000 ₫. The spec rule ("half the listed price, rounded up to 100.000 ₫") gives 5.500.000 ₫, and both screens use it.

- [ ] **Step 1: Write the failing tests**

`OfferRangeTest.kt`:

```kotlin
package vn.shopnexus.core.domain

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import vn.shopnexus.core.model.Vnd

class OfferRangeTest {
    private val chat = offerRange(listed = Vnd(10_900_000), counter = Vnd(10_600_000))
    private val detail = offerRange(listed = Vnd(10_900_000), counter = null)

    @Test
    fun floorIsHalfTheListedPriceRoundedUpToTheStep() {
        assertThat(chat.floor).isEqualTo(Vnd(5_500_000))
        assertThat(offerRange(Vnd(1_000_000), null).floor).isEqualTo(Vnd(500_000))
    }

    @Test
    fun ceilingIsTheCounterOrElseTheListedPrice() {
        assertThat(chat.ceiling).isEqualTo(Vnd(10_600_000))
        assertThat(chat.highest).isEqualTo(Vnd(10_500_000))
        assertThat(detail.ceiling).isEqualTo(Vnd(10_900_000))
        assertThat(detail.highest).isEqualTo(Vnd(10_800_000))
    }

    @Test
    fun steppingStaysInsideTheRange() {
        assertThat(chat.stepped(Vnd(10_500_000), up = false)).isEqualTo(Vnd(10_400_000))
        assertThat(chat.stepped(Vnd(10_500_000), up = true)).isEqualTo(Vnd(10_500_000))
        assertThat(chat.stepped(Vnd(5_500_000), up = false)).isEqualTo(Vnd(5_500_000))
    }

    @Test
    fun checkSaysWhatIsWrongOrTheGap() {
        assertThat(chat.check(null)).isEqualTo(OfferCheck.Empty)
        assertThat(chat.check(Vnd(5_000_000))).isEqualTo(OfferCheck.TooLow(Vnd(5_500_000)))
        assertThat(chat.check(Vnd(10_600_000))).isEqualTo(OfferCheck.NotBelow(Vnd(10_600_000)))
        assertThat(chat.check(Vnd(10_400_000))).isEqualTo(OfferCheck.Ok(Vnd(200_000)))
        assertThat(detail.check(Vnd(10_400_000))).isEqualTo(OfferCheck.Ok(Vnd(500_000)))
    }
}
```

`OfferInputTest.kt` (Review Focus 1):

```kotlin
package vn.shopnexus.core.domain

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import vn.shopnexus.core.model.Vnd

class OfferInputTest {
    @Test
    fun onlyDigitsCount() {
        assertThat(parseOfferInput("10.500.000")).isEqualTo(Vnd(10_500_000))
        assertThat(parseOfferInput(" 10 500 000 ₫")).isEqualTo(Vnd(10_500_000))
        assertThat(parseOfferInput("10,5tr")).isEqualTo(Vnd(105))
    }

    @Test
    fun emptyOrZeroIsNoAmount() {
        assertThat(parseOfferInput("")).isNull()
        assertThat(parseOfferInput("₫")).isNull()
        assertThat(parseOfferInput("0")).isNull()
    }

    @Test
    fun absurdlyLongInputDoesNotOverflow() {
        assertThat(parseOfferInput("9".repeat(40))).isNull()
    }

    @Test
    fun aParsedTypoIsReportedAsTooLow() {
        val range = offerRange(Vnd(10_900_000), Vnd(10_600_000))
        assertThat(range.check(parseOfferInput("10,5tr"))).isEqualTo(OfferCheck.TooLow(Vnd(5_500_000)))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./gradlew :core:domain:test --tests "*Offer*"`
Expected: FAIL, `Unresolved reference 'offerRange'`.

- [ ] **Step 3: Write the implementation**

`Offers.kt`:

```kotlin
package vn.shopnexus.core.domain

import vn.shopnexus.core.model.Vnd

val OFFER_STEP = Vnd(100_000)

/** Amounts an offer may take: from [floor] up to, not including, [ceiling], in [step]s. */
data class OfferRange(val floor: Vnd, val ceiling: Vnd, val step: Vnd) {
    val highest: Vnd
        get() = Vnd(((ceiling.amount - 1) / step.amount) * step.amount)

    fun stepped(from: Vnd, up: Boolean): Vnd {
        val next = if (up) from + step else from - step
        return Vnd(next.amount.coerceIn(floor.amount, maxOf(floor.amount, highest.amount)))
    }

    fun check(amount: Vnd?): OfferCheck = when {
        amount == null -> OfferCheck.Empty
        amount < floor -> OfferCheck.TooLow(floor)
        amount >= ceiling -> OfferCheck.NotBelow(ceiling)
        else -> OfferCheck.Ok(ceiling - amount)
    }
}

sealed interface OfferCheck {
    data object Empty : OfferCheck
    data class TooLow(val floor: Vnd) : OfferCheck
    data class NotBelow(val ceiling: Vnd) : OfferCheck
    data class Ok(val gap: Vnd) : OfferCheck
}

/** The counter, when the seller has made one, is the ceiling; otherwise the listed price is. */
fun offerRange(listed: Vnd, counter: Vnd?): OfferRange {
    val half = (listed.amount + 1) / 2
    val floor = ((half + OFFER_STEP.amount - 1) / OFFER_STEP.amount) * OFFER_STEP.amount
    return OfferRange(Vnd(floor), counter ?: listed, OFFER_STEP)
}

/** Typed or pasted text: every non-digit is dropped. 19 digits or more cannot be a price. */
fun parseOfferInput(text: String): Vnd? {
    val digits = text.filter(Char::isDigit).trimStart('0')
    if (digits.isEmpty() || digits.length > 18) return null
    return Vnd(digits.toLong())
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./gradlew :core:domain:test`
Expected: PASS, 13 tests.

- [ ] **Step 5: Commit**

```bash
git add core/domain
git commit -m "feat(domain): add the offer range and the offer input parser

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Reputation points and tiers (`:core:domain`)

**Files:**
- Create: `app2/core/domain/src/main/kotlin/vn/shopnexus/core/domain/Reputation.kt`
- Test: `app2/core/domain/src/test/kotlin/vn/shopnexus/core/domain/ReputationTest.kt`

**Interfaces:**
- Consumes: `Tier` (Task 3).
- Produces:
  ```kotlin
  enum class ReputationEvent(val points: Int) {
      DEAL(10), RATED_5(5), RATED_4(2), SELF_REFUND(15), FAST_REPLY_MONTH(20), IDENTITY(100),
      RATED_LOW(-15), CANCEL_AFTER_AGREE(-20), CANCEL_MEETING_LATE(-30)
  }
  data class ScoredEvent(val event: ReputationEvent, val at: Instant)
  fun pointsFor(event: ReputationEvent): Int
  fun tierFor(score: Int): Tier
  fun score(events: List<ScoredEvent>, now: Instant): Int   // 0..1000, events older than 365 days count half
  ```

- [ ] **Step 1: Write the failing test**

```kotlin
package vn.shopnexus.core.domain

import com.google.common.truth.Truth.assertThat
import java.time.Duration
import java.time.Instant
import org.junit.Test
import vn.shopnexus.core.model.Tier

class ReputationTest {
    private val now = Instant.parse("2026-10-15T08:10:00Z")

    @Test
    fun pointsMatchTheTable() {
        assertThat(pointsFor(ReputationEvent.DEAL)).isEqualTo(10)
        assertThat(pointsFor(ReputationEvent.SELF_REFUND)).isEqualTo(15)
        assertThat(pointsFor(ReputationEvent.IDENTITY)).isEqualTo(100)
        assertThat(pointsFor(ReputationEvent.CANCEL_MEETING_LATE)).isEqualTo(-30)
    }

    @Test
    fun tiersStartAtTheirThresholds() {
        assertThat(tierFor(0)).isEqualTo(Tier.NEW)
        assertThat(tierFor(199)).isEqualTo(Tier.NEW)
        assertThat(tierFor(200)).isEqualTo(Tier.TRUSTED)
        assertThat(tierFor(499)).isEqualTo(Tier.TRUSTED)
        assertThat(tierFor(500)).isEqualTo(Tier.REPUTABLE)
        assertThat(tierFor(800)).isEqualTo(Tier.TOP)
    }

    @Test
    fun eventsOlderThanAYearCountHalf() {
        val events = listOf(
            ScoredEvent(ReputationEvent.IDENTITY, now.minus(Duration.ofDays(400))),
            ScoredEvent(ReputationEvent.DEAL, now.minus(Duration.ofDays(10))),
            ScoredEvent(ReputationEvent.CANCEL_AFTER_AGREE, now.minus(Duration.ofDays(500))),
        )
        assertThat(score(events, now)).isEqualTo(50 + 10 - 10)
    }

    @Test
    fun scoreStaysBetweenZeroAndAThousand() {
        assertThat(score(listOf(ScoredEvent(ReputationEvent.CANCEL_MEETING_LATE, now)), now)).isEqualTo(0)
        assertThat(score(List(20) { ScoredEvent(ReputationEvent.IDENTITY, now) }, now)).isEqualTo(1000)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./gradlew :core:domain:test --tests "*ReputationTest*"`
Expected: FAIL, `Unresolved reference 'ReputationEvent'`.

- [ ] **Step 3: Write the implementation**

```kotlin
package vn.shopnexus.core.domain

import java.time.Duration
import java.time.Instant
import vn.shopnexus.core.model.Tier

/** Only events the app observes earn or cost points; there is none for winning or losing a dispute. */
enum class ReputationEvent(val points: Int) {
    DEAL(10), RATED_5(5), RATED_4(2), SELF_REFUND(15), FAST_REPLY_MONTH(20), IDENTITY(100),
    RATED_LOW(-15), CANCEL_AFTER_AGREE(-20), CANCEL_MEETING_LATE(-30),
}

data class ScoredEvent(val event: ReputationEvent, val at: Instant)

private val FULL_WEIGHT = Duration.ofDays(365)

fun pointsFor(event: ReputationEvent): Int = event.points

fun tierFor(score: Int): Tier = when {
    score >= 800 -> Tier.TOP
    score >= 500 -> Tier.REPUTABLE
    score >= 200 -> Tier.TRUSTED
    else -> Tier.NEW
}

fun score(events: List<ScoredEvent>, now: Instant): Int =
    events.sumOf { scored ->
        val old = Duration.between(scored.at, now) > FULL_WEIGHT
        if (old) scored.event.points / 2 else scored.event.points
    }.coerceIn(0, 1000)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./gradlew :core:domain:test`
Expected: PASS, 17 tests.

- [ ] **Step 5: Commit**

```bash
git add core/domain
git commit -m "feat(domain): add reputation points, decay and tiers

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: The rights ladder (`:core:domain`)

**Files:**
- Create: `app2/core/domain/src/main/kotlin/vn/shopnexus/core/domain/Rights.kt`
- Test: `app2/core/domain/src/test/kotlin/vn/shopnexus/core/domain/RightsTest.kt`

**Interfaces:**
- Produces:
  ```kotlin
  data class Stats90(val codOrders: Int, val codRefused: Int, val lastRefusalAt: Instant?)
  data class Rights(val codOpenCap: Int, val listingCap: Int, val codBlockedUntil: Instant?)
  const val MIN_ORDERS_FOR_SANCTIONS = 5
  fun rightsFor(tier: Tier, stats: Stats90, now: Instant): Rights
  ```

- [ ] **Step 1: Write the failing test**

```kotlin
package vn.shopnexus.core.domain

import com.google.common.truth.Truth.assertThat
import java.time.Duration
import java.time.Instant
import org.junit.Test
import vn.shopnexus.core.model.Tier

class RightsTest {
    private val now = Instant.parse("2026-10-15T08:10:00Z")
    private val recently = now.minus(Duration.ofDays(3))

    @Test
    fun tiersGrantCodOrdersAndListings() {
        val clean = Stats90(codOrders = 0, codRefused = 0, lastRefusalAt = null)
        assertThat(rightsFor(Tier.NEW, clean, now)).isEqualTo(Rights(2, 5, null))
        assertThat(rightsFor(Tier.TRUSTED, clean, now)).isEqualTo(Rights(5, 20, null))
        assertThat(rightsFor(Tier.REPUTABLE, clean, now).codOpenCap).isEqualTo(10)
        assertThat(rightsFor(Tier.TOP, clean, now).codOpenCap).isEqualTo(20)
    }

    @Test
    fun fewerThanFiveOrdersAreNotJudged() {
        assertThat(rightsFor(Tier.TRUSTED, Stats90(4, 3, recently), now).codOpenCap).isEqualTo(5)
    }

    @Test
    fun twentyPercentRefusalsLimitCodToOneOpenOrder() {
        assertThat(rightsFor(Tier.TRUSTED, Stats90(5, 1, recently), now).codOpenCap).isEqualTo(1)
        assertThat(rightsFor(Tier.TRUSTED, Stats90(10, 1, recently), now).codOpenCap).isEqualTo(5)
    }

    @Test
    fun thirtyFivePercentRefusalsRemoveCodForThirtyDays() {
        val rights = rightsFor(Tier.TRUSTED, Stats90(5, 2, recently), now)
        assertThat(rights.codOpenCap).isEqualTo(0)
        assertThat(rights.codBlockedUntil).isEqualTo(recently.plus(Duration.ofDays(30)))
    }

    @Test
    fun thirtyCleanDaysLiftTheStep() {
        val longAgo = now.minus(Duration.ofDays(30))
        assertThat(rightsFor(Tier.TRUSTED, Stats90(5, 2, longAgo), now)).isEqualTo(Rights(5, 20, null))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./gradlew :core:domain:test --tests "*RightsTest*"`
Expected: FAIL, `Unresolved reference 'rightsFor'`.

- [ ] **Step 3: Write the implementation**

```kotlin
package vn.shopnexus.core.domain

import java.time.Duration
import java.time.Instant
import vn.shopnexus.core.model.Tier

/** A user's COD figures over the last 90 days. */
data class Stats90(val codOrders: Int, val codRefused: Int, val lastRefusalAt: Instant?)

data class Rights(val codOpenCap: Int, val listingCap: Int, val codBlockedUntil: Instant?)

const val MIN_ORDERS_FOR_SANCTIONS = 5
private val CLEAN_PERIOD = Duration.ofDays(30)
private val COD_CAP = mapOf(Tier.NEW to 2, Tier.TRUSTED to 5, Tier.REPUTABLE to 10, Tier.TOP to 20)
private val LISTING_CAP = mapOf(Tier.NEW to 5, Tier.TRUSTED to 20, Tier.REPUTABLE to 20, Tier.TOP to 20)

/**
 * One ladder: tiers grant rights, refusals take them away. Statistics decide,
 * with no ruling on any single case.
 */
fun rightsFor(tier: Tier, stats: Stats90, now: Instant): Rights {
    val base = Rights(COD_CAP.getValue(tier), LISTING_CAP.getValue(tier), codBlockedUntil = null)
    val last = stats.lastRefusalAt ?: return base
    if (stats.codOrders < MIN_ORDERS_FOR_SANCTIONS) return base
    if (Duration.between(last, now) >= CLEAN_PERIOD) return base
    val rate = stats.codRefused.toDouble() / stats.codOrders
    return when {
        rate >= 0.35 -> base.copy(codOpenCap = 0, codBlockedUntil = last.plus(CLEAN_PERIOD))
        rate >= 0.20 -> base.copy(codOpenCap = 1)
        else -> base
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./gradlew :core:domain:test`
Expected: PASS, 22 tests.

- [ ] **Step 5: Commit**

```bash
git add core/domain
git commit -m "feat(domain): add the rights ladder

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Posting gate and money sentences (`:core:domain`)

**Files:**
- Create: `app2/core/domain/src/main/kotlin/vn/shopnexus/core/domain/Posting.kt`
- Create: `app2/core/domain/src/main/kotlin/vn/shopnexus/core/domain/MoneyNotes.kt`
- Test: `app2/core/domain/src/test/kotlin/vn/shopnexus/core/domain/PostingAndMoneyTest.kt`

**Interfaces:**
- Produces:
  ```kotlin
  fun canPost(draft: ListingDraft): Boolean
  enum class MoneyStep { LISTING_CONDITION, LISTING_PATHS, DEAL_AGREED, DEAL_MEETING, HANDOVER_CHECKLIST }
  fun moneyNotes(step: MoneyStep, price: Vnd): List<MoneyKey>
  ```

- [ ] **Step 1: Write the failing test**

```kotlin
package vn.shopnexus.core.domain

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import vn.shopnexus.core.model.AiMark
import vn.shopnexus.core.model.HandoverPath
import vn.shopnexus.core.model.ListingDraft
import vn.shopnexus.core.model.MarkDecision
import vn.shopnexus.core.model.MoneyKey
import vn.shopnexus.core.model.Vnd

class PostingAndMoneyTest {
    private fun draft(vararg decisions: MarkDecision) = ListingDraft(
        title = "iPhone 11 64GB Trắng, máy zin", price = Vnd(4_500_000), paths = setOf(HandoverPath.MEET),
        aiMarks = decisions.map { AiMark("Xước nhẹ ở mặt lưng", it) },
    )

    @Test
    fun aMarkTheModelSawMustBeAnswered() {
        assertThat(canPost(draft(MarkDecision.PENDING))).isFalse()
        assertThat(canPost(draft(MarkDecision.DECLARED))).isTrue()
        assertThat(canPost(draft(MarkDecision.DISMISSED, MarkDecision.DECLARED))).isTrue()
        assertThat(canPost(draft())).isTrue()
    }

    @Test
    fun listingDetailSaysWhatEachPathProtects() {
        assertThat(moneyNotes(MoneyStep.LISTING_PATHS, Vnd(10_900_000)))
            .containsExactly(MoneyKey.MEET, MoneyKey.OVER_LIMIT, MoneyKey.NO_HOLD).inOrder()
        assertThat(moneyNotes(MoneyStep.LISTING_PATHS, Vnd(3_800_000)))
            .containsExactly(MoneyKey.MEET, MoneyKey.NO_HOLD).inOrder()
        assertThat(moneyNotes(MoneyStep.LISTING_CONDITION, Vnd(10_900_000))).containsExactly(MoneyKey.DECLARED)
    }

    @Test
    fun theChatConsoleSaysItAtEachStep() {
        assertThat(moneyNotes(MoneyStep.DEAL_AGREED, Vnd(10_500_000)))
            .containsExactly(MoneyKey.OVER_LIMIT, MoneyKey.MEET).inOrder()
        assertThat(moneyNotes(MoneyStep.DEAL_MEETING, Vnd(10_500_000))).containsExactly(MoneyKey.AFTER_PAY)
        assertThat(moneyNotes(MoneyStep.HANDOVER_CHECKLIST, Vnd(10_500_000))).containsExactly(MoneyKey.DECLARED)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./gradlew :core:domain:test --tests "*PostingAndMoneyTest*"`
Expected: FAIL, `Unresolved reference 'canPost'`.

- [ ] **Step 3: Write the implementation**

`Posting.kt`:

```kotlin
package vn.shopnexus.core.domain

import vn.shopnexus.core.model.ListingDraft
import vn.shopnexus.core.model.MarkDecision

/** The model guards posting: every mark it saw is declared or dismissed first. */
fun canPost(draft: ListingDraft): Boolean = draft.aiMarks.none { it.decision == MarkDecision.PENDING }
```

`MoneyNotes.kt`:

```kotlin
package vn.shopnexus.core.domain

import vn.shopnexus.core.model.MoneyKey
import vn.shopnexus.core.model.Vnd

enum class MoneyStep { LISTING_CONDITION, LISTING_PATHS, DEAL_AGREED, DEAL_MEETING, HANDOVER_CHECKLIST }

/** Which money sentences a step shows, in order. The words are the same on every screen. */
fun moneyNotes(step: MoneyStep, price: Vnd): List<MoneyKey> = when (step) {
    MoneyStep.LISTING_CONDITION, MoneyStep.HANDOVER_CHECKLIST -> listOf(MoneyKey.DECLARED)
    MoneyStep.LISTING_PATHS -> buildList {
        add(MoneyKey.MEET)
        if (!codAllowed(price)) add(MoneyKey.OVER_LIMIT)
        add(MoneyKey.NO_HOLD)
    }
    MoneyStep.DEAL_AGREED -> buildList {
        if (!codAllowed(price)) add(MoneyKey.OVER_LIMIT)
        add(MoneyKey.MEET)
    }
    MoneyStep.DEAL_MEETING -> listOf(MoneyKey.AFTER_PAY)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./gradlew :core:domain:test`
Expected: PASS, 25 tests.

- [ ] **Step 5: Commit**

```bash
git add core/domain
git commit -m "feat(domain): add the posting gate and the money sentences per step

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: The deal console state machine (`:core:domain`)

The Chat console's state comes from the deal (server truth) plus the buyer's offer draft (local). Events turn into a new draft or a `DealCommand`. The ViewModel in Task 21 only wires this to the repository.

**Files:**
- Create: `app2/core/domain/src/main/kotlin/vn/shopnexus/core/domain/DealConsole.kt`
- Test: `app2/core/domain/src/test/kotlin/vn/shopnexus/core/domain/DealConsoleTest.kt`

**Interfaces:**
- Consumes: `Deal`, `DealCommand`, `Meeting`, `MeetPoint`, `PriceInsight` (Task 3); `offerRange`, `OfferRange`, `OfferCheck`, `parseOfferInput` (Task 5).
- Produces:
  ```kotlin
  sealed interface ConsoleState {
      data class Countered(val counter: Vnd, val insight: PriceInsight?, val expiresAt: Instant?) : ConsoleState
      data class Offering(val draft: Vnd?, val range: OfferRange, val check: OfferCheck) : ConsoleState
      data class Waiting(val offer: Vnd) : ConsoleState
      data class Agreed(val price: Vnd, val meeting: Meeting?) : ConsoleState
      data class Proposing(val meeting: Meeting) : ConsoleState
      data class AtMeeting(val meeting: Meeting, val checked: Int, val total: Int) : ConsoleState
      data object Received : ConsoleState
      data class Done(val stars: Int) : ConsoleState
  }
  sealed interface ConsoleEvent {
      data object StartOffer; data class StepOffer(val up: Boolean); data class PickOffer(val amount: Vnd)
      data class TypeOffer(val text: String); data object CancelOffer; data object SendOffer
      data object Accept; data object Withdraw; data object ConfirmMeeting
      data class Propose(val at: Instant, val place: MeetPoint); data class Check(val itemId: String, val checked: Boolean)
      data class Scan(val code: String); data class Rate(val stars: Int)
  }   // every member implements ConsoleEvent
  data class ConsoleDraft(val editing: Boolean, val amount: Vnd?)
  data class ConsoleStep(val draft: ConsoleDraft, val command: DealCommand?)
  object DealConsole {
      fun state(deal: Deal, draft: ConsoleDraft): ConsoleState
      fun reduce(deal: Deal, draft: ConsoleDraft, event: ConsoleEvent): ConsoleStep
      fun needsCheckWarning(state: ConsoleState): Boolean   // AtMeeting with unchecked items
  }
  ```

- [ ] **Step 1: Write the failing test**

```kotlin
package vn.shopnexus.core.domain

import com.google.common.truth.Truth.assertThat
import java.time.Instant
import org.junit.Test
import vn.shopnexus.core.model.CheckItem
import vn.shopnexus.core.model.Deal
import vn.shopnexus.core.model.DealCommand
import vn.shopnexus.core.model.DealId
import vn.shopnexus.core.model.DealStage
import vn.shopnexus.core.model.HandoverPath
import vn.shopnexus.core.model.ListingId
import vn.shopnexus.core.model.MeetPoint
import vn.shopnexus.core.model.Meeting
import vn.shopnexus.core.model.Offer
import vn.shopnexus.core.model.OfferStatus
import vn.shopnexus.core.model.Party
import vn.shopnexus.core.model.UserId
import vn.shopnexus.core.model.Vnd

class DealConsoleTest {
    private val t = Instant.parse("2026-10-15T07:10:00Z")
    private val landmark = MeetPoint("Sảnh Landmark 81", "Có bảo vệ, đông người")
    private val idle = ConsoleDraft(editing = false, amount = null)
    private val countered = Deal(
        id = DealId("d-kiet"), listingId = ListingId("p-iphone13"), buyerId = UserId("u-linh"), sellerId = UserId("u-kiet"),
        listedPrice = Vnd(10_900_000), path = HandoverPath.MEET, stage = DealStage.NEGOTIATE,
        offers = listOf(
            Offer(Party.BUYER, Vnd(10_400_000), t, OfferStatus.SUPERSEDED),
            Offer(Party.SELLER, Vnd(10_600_000), t, OfferStatus.OPEN),
        ),
        checklist = List(6) { CheckItem("k$it", "Kiểm $it", "check", checked = false) },
    )

    @Test
    fun aCounterIsShownWithItsJudgmentAndExpiry() {
        assertThat(DealConsole.state(countered, idle)).isEqualTo(ConsoleState.Countered(Vnd(10_600_000), null, null))
    }

    @Test
    fun startingAnOfferProposesOneStepBelowTheCounter() {
        val step = DealConsole.reduce(countered, idle, ConsoleEvent.StartOffer)
        assertThat(step.draft).isEqualTo(ConsoleDraft(editing = true, amount = Vnd(10_500_000)))
        assertThat(step.command).isNull()
        val state = DealConsole.state(countered, step.draft) as ConsoleState.Offering
        assertThat(state.check).isEqualTo(OfferCheck.Ok(Vnd(100_000)))
    }

    @Test
    fun steppingPickingAndTypingChangeOnlyTheDraft() {
        var draft = ConsoleDraft(editing = true, amount = Vnd(10_500_000))
        draft = DealConsole.reduce(countered, draft, ConsoleEvent.StepOffer(up = false)).draft
        assertThat(draft.amount).isEqualTo(Vnd(10_400_000))
        draft = DealConsole.reduce(countered, draft, ConsoleEvent.PickOffer(Vnd(10_300_000))).draft
        assertThat(draft.amount).isEqualTo(Vnd(10_300_000))
        draft = DealConsole.reduce(countered, draft, ConsoleEvent.TypeOffer("10.700.000")).draft
        assertThat((DealConsole.state(countered, draft) as ConsoleState.Offering).check)
            .isEqualTo(OfferCheck.NotBelow(Vnd(10_600_000)))
    }

    @Test
    fun anInvalidOfferIsNotSent() {
        val draft = ConsoleDraft(editing = true, amount = Vnd(10_700_000))
        val step = DealConsole.reduce(countered, draft, ConsoleEvent.SendOffer)
        assertThat(step.command).isNull()
        assertThat(step.draft).isEqualTo(draft)
    }

    @Test
    fun aValidOfferBecomesACommandAndClosesTheEditor() {
        val step = DealConsole.reduce(countered, ConsoleDraft(true, Vnd(10_500_000)), ConsoleEvent.SendOffer)
        assertThat(step.command).isEqualTo(DealCommand.SendOffer(Vnd(10_500_000), null))
        assertThat(step.draft).isEqualTo(idle)
    }

    @Test
    fun anOpenOfferIsWaiting() {
        val waiting = countered.copy(offers = countered.offers + Offer(Party.BUYER, Vnd(10_500_000), t, OfferStatus.OPEN))
        assertThat(DealConsole.state(waiting, idle)).isEqualTo(ConsoleState.Waiting(Vnd(10_500_000)))
        assertThat(DealConsole.reduce(waiting, idle, ConsoleEvent.Withdraw).command).isEqualTo(DealCommand.WithdrawOffer)
    }

    @Test
    fun theAgreedStagesFollowTheMeeting() {
        val sellerProposal = Meeting(t, landmark, Party.SELLER, confirmed = false)
        val agreed = countered.copy(stage = DealStage.ARRANGE, agreedPrice = Vnd(10_500_000), meeting = sellerProposal)
        assertThat(DealConsole.state(agreed, idle)).isEqualTo(ConsoleState.Agreed(Vnd(10_500_000), sellerProposal))
        assertThat(DealConsole.reduce(agreed, idle, ConsoleEvent.ConfirmMeeting).command).isEqualTo(DealCommand.ConfirmMeeting)

        val mine = Meeting(t, landmark, Party.BUYER, confirmed = false)
        assertThat(DealConsole.state(agreed.copy(meeting = mine), idle)).isEqualTo(ConsoleState.Proposing(mine))

        val confirmed = agreed.copy(stage = DealStage.HANDOVER, meeting = sellerProposal.copy(confirmed = true),
            checklist = agreed.checklist.mapIndexed { i, c -> c.copy(checked = i < 2) })
        val atMeeting = DealConsole.state(confirmed, idle)
        assertThat(atMeeting).isEqualTo(ConsoleState.AtMeeting(sellerProposal.copy(confirmed = true), checked = 2, total = 6))
        assertThat(DealConsole.needsCheckWarning(atMeeting)).isTrue()
    }

    @Test
    fun scanningAndRatingBecomeCommands() {
        val received = countered.copy(stage = DealStage.RATE)
        assertThat(DealConsole.state(received, idle)).isEqualTo(ConsoleState.Received)
        assertThat(DealConsole.reduce(received, idle, ConsoleEvent.Rate(5)).command).isEqualTo(DealCommand.Rate(5))
        assertThat(DealConsole.state(received.copy(stage = DealStage.DONE, rating = 5), idle)).isEqualTo(ConsoleState.Done(5))
        assertThat(DealConsole.reduce(received, idle, ConsoleEvent.Scan("SNX-KIET")).command)
            .isEqualTo(DealCommand.RecordHandover("SNX-KIET"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./gradlew :core:domain:test --tests "*DealConsoleTest*"`
Expected: FAIL, `Unresolved reference 'DealConsole'`.

- [ ] **Step 3: Write the implementation**

```kotlin
package vn.shopnexus.core.domain

import java.time.Instant
import vn.shopnexus.core.model.Deal
import vn.shopnexus.core.model.DealCommand
import vn.shopnexus.core.model.DealStage
import vn.shopnexus.core.model.MeetPoint
import vn.shopnexus.core.model.Meeting
import vn.shopnexus.core.model.Party
import vn.shopnexus.core.model.PriceInsight
import vn.shopnexus.core.model.Vnd

sealed interface ConsoleState {
    data class Countered(val counter: Vnd, val insight: PriceInsight?, val expiresAt: Instant?) : ConsoleState
    data class Offering(val draft: Vnd?, val range: OfferRange, val check: OfferCheck) : ConsoleState
    data class Waiting(val offer: Vnd) : ConsoleState
    data class Agreed(val price: Vnd, val meeting: Meeting?) : ConsoleState
    data class Proposing(val meeting: Meeting) : ConsoleState
    data class AtMeeting(val meeting: Meeting, val checked: Int, val total: Int) : ConsoleState
    data object Received : ConsoleState
    data class Done(val stars: Int) : ConsoleState
}

sealed interface ConsoleEvent {
    data object StartOffer : ConsoleEvent
    data class StepOffer(val up: Boolean) : ConsoleEvent
    data class PickOffer(val amount: Vnd) : ConsoleEvent
    data class TypeOffer(val text: String) : ConsoleEvent
    data object CancelOffer : ConsoleEvent
    data object SendOffer : ConsoleEvent
    data object Accept : ConsoleEvent
    data object Withdraw : ConsoleEvent
    data object ConfirmMeeting : ConsoleEvent
    data class Propose(val at: Instant, val place: MeetPoint) : ConsoleEvent
    data class Check(val itemId: String, val checked: Boolean) : ConsoleEvent
    data class Scan(val code: String) : ConsoleEvent
    data class Rate(val stars: Int) : ConsoleEvent
}

/** The buyer's unsent offer: local to the screen, kept across recreation by the ViewModel. */
data class ConsoleDraft(val editing: Boolean, val amount: Vnd?)

data class ConsoleStep(val draft: ConsoleDraft, val command: DealCommand?)

object DealConsole {
    private val IDLE = ConsoleDraft(editing = false, amount = null)

    private fun Deal.counterOrListed(): Vnd = openCounter?.amount ?: listedPrice
    private fun Deal.range(): OfferRange = offerRange(listedPrice, openCounter?.amount)

    fun state(deal: Deal, draft: ConsoleDraft): ConsoleState = when (deal.stage) {
        DealStage.NEGOTIATE -> when {
            draft.editing -> deal.range().let { ConsoleState.Offering(draft.amount, it, it.check(draft.amount)) }
            deal.openOffer != null -> ConsoleState.Waiting(deal.openOffer!!.amount)
            else -> ConsoleState.Countered(deal.counterOrListed(), deal.priceInsight, deal.counterExpiresAt)
        }
        DealStage.ARRANGE -> {
            val meeting = deal.meeting
            if (meeting != null && meeting.proposedBy == Party.BUYER && !meeting.confirmed) ConsoleState.Proposing(meeting)
            else ConsoleState.Agreed(deal.agreedPrice ?: deal.counterOrListed(), meeting)
        }
        DealStage.HANDOVER -> ConsoleState.AtMeeting(
            meeting = requireNotNull(deal.meeting) { "A deal at hand-over has a meeting" },
            checked = deal.checklist.count { it.checked },
            total = deal.checklist.size,
        )
        DealStage.RATE -> ConsoleState.Received
        DealStage.DONE -> ConsoleState.Done(deal.rating ?: 0)
    }

    fun reduce(deal: Deal, draft: ConsoleDraft, event: ConsoleEvent): ConsoleStep {
        val range = deal.range()
        fun edit(amount: Vnd?) = ConsoleStep(ConsoleDraft(editing = true, amount = amount), null)
        fun send(command: DealCommand) = ConsoleStep(draft, command)
        return when (event) {
            ConsoleEvent.StartOffer -> edit(range.stepped(deal.counterOrListed(), up = false))
            is ConsoleEvent.StepOffer -> edit(range.stepped(draft.amount ?: range.highest, event.up))
            is ConsoleEvent.PickOffer -> edit(event.amount)
            is ConsoleEvent.TypeOffer -> edit(parseOfferInput(event.text))
            ConsoleEvent.CancelOffer -> ConsoleStep(IDLE, null)
            ConsoleEvent.SendOffer -> {
                val amount = draft.amount
                if (amount != null && range.check(amount) is OfferCheck.Ok) ConsoleStep(IDLE, DealCommand.SendOffer(amount, null))
                else ConsoleStep(draft, null)
            }
            ConsoleEvent.Accept -> send(DealCommand.AcceptCounter)
            ConsoleEvent.Withdraw -> send(DealCommand.WithdrawOffer)
            ConsoleEvent.ConfirmMeeting -> send(DealCommand.ConfirmMeeting)
            is ConsoleEvent.Propose -> send(DealCommand.ProposeMeeting(event.at, event.place))
            is ConsoleEvent.Check -> send(DealCommand.SetCheck(event.itemId, event.checked))
            is ConsoleEvent.Scan -> send(DealCommand.RecordHandover(event.code))
            is ConsoleEvent.Rate -> send(DealCommand.Rate(event.stars))
        }
    }

    /** Scanning settles the hand-over, so unchecked items are worth one warning first. */
    fun needsCheckWarning(state: ConsoleState): Boolean = state is ConsoleState.AtMeeting && state.checked < state.total
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./gradlew :core:domain:test`
Expected: PASS, 33 tests.

- [ ] **Step 5: Commit**

```bash
git add core/domain
git commit -m "feat(domain): add the deal console state machine

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```


---

### Task 10: Data contracts and fixtures

Repository interfaces, the fixture files, the loader, money and time formatting shared by the fakes and the UI, and the clock that makes fixture times read as "now".

**Files:**
- Create: `app2/build-logic/convention/src/main/kotlin/AndroidLibraryConventionPlugin.kt`
- Modify: `app2/build-logic/convention/build.gradle.kts` (register `shopnexus.android.library`)
- Modify: `app2/settings.gradle.kts` (add `include(":core:data", ":core:testing")`)
- Create: `app2/core/model/src/main/kotlin/vn/shopnexus/core/model/MoneyFormat.kt`
- Test: `app2/core/model/src/test/kotlin/vn/shopnexus/core/model/MoneyFormatTest.kt`
- Create: `app2/core/domain/src/main/kotlin/vn/shopnexus/core/domain/RelativeTime.kt`
- Test: `app2/core/domain/src/test/kotlin/vn/shopnexus/core/domain/RelativeTimeTest.kt`
- Create: `app2/core/data/build.gradle.kts`
- Create: `app2/core/data/src/main/kotlin/vn/shopnexus/core/data/Repositories.kt`
- Create: `app2/core/data/src/main/kotlin/vn/shopnexus/core/data/fake/Fixtures.kt`
- Create: `app2/core/data/src/main/resources/fixtures/home.json`, `fresh.json`, `listing-p-iphone13.json`, `chat-d-kiet.json`
- Test: `app2/core/data/src/test/kotlin/vn/shopnexus/core/data/fake/FixturesTest.kt`
- Create: `app2/core/testing/build.gradle.kts`
- Create: `app2/core/testing/src/main/kotlin/vn/shopnexus/core/testing/SchedulerClock.kt`
- Create: `app2/core/testing/src/main/kotlin/vn/shopnexus/core/testing/MainDispatcherRule.kt`

**Interfaces:**
- Consumes: every model type (Task 3).
- Produces:
  ```kotlin
  // :core:model
  fun Vnd.full(): String      // "10.900.000 ₫" (non-breaking space before ₫)
  fun Vnd.digits(): String    // "10.900.000"
  fun Vnd.short(): String     // "10,9 tr" from 1.000.000 up, else digits()
  fun Vnd.cardParts(): Pair<String, String>   // a card price: ("10,9", " tr ₫") from 10 triệu up, else ("2.300.000", " ₫")
  // :core:domain
  val VN_ZONE: ZoneId          // Asia/Ho_Chi_Minh
  fun meetingLabel(at: Instant, now: Instant, zone: ZoneId): String   // "19:00 hôm nay", "19:00 mai", "19:00 17/10"
  fun todayAt(hour: Int, minute: Int, now: Instant, zone: ZoneId): Instant
  // :core:data
  interface HomeRepository { fun feed(): Flow<HomeFeed>; suspend fun refresh(): Result<Int> }
  interface ListingRepository { fun detail(id: ListingId): Flow<ListingDetail?>; suspend fun setSaved(id: ListingId, saved: Boolean): Result<Unit>
                                suspend fun report(id: ListingId, reason: ReportReason): Result<Unit> }
  interface DealRepository {
      fun chat(id: DealId): Flow<ChatView?>
      fun counterpartTyping(id: DealId): Flow<Boolean>
      suspend fun send(id: DealId, command: DealCommand): Result<Deal>
  }
  interface QrScanner { suspend fun scan(): Result<String> }
  object Fixtures { val NOW: Instant; fun home(): HomeFeed; fun fresh(): List<ListingSummary>; fun detail(id: String): ListingDetail; fun chat(id: String): ChatView }
  fun fixtureClock(base: Clock = Clock.systemUTC()): Clock   // reads Fixtures.NOW at start, then runs
  // :core:testing
  class SchedulerClock(scheduler: TestCoroutineScheduler, start: Instant = Fixtures.NOW, zone: ZoneId = VN_ZONE) : Clock
  class MainDispatcherRule(val dispatcher: TestDispatcher = UnconfinedTestDispatcher()) : TestWatcher
  ```

- [ ] **Step 1: Add the Android library convention plugin**

`app2/build-logic/convention/src/main/kotlin/AndroidLibraryConventionPlugin.kt`:

```kotlin
import com.android.build.api.dsl.LibraryExtension
import org.gradle.api.JavaVersion
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.dependencies

/** Android libraries without Compose (`:core:data`, `:core:testing`). */
class AndroidLibraryConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("com.android.library")
        pluginManager.apply("org.jetbrains.kotlin.plugin.serialization")
        extensions.configure<LibraryExtension> {
            compileSdk = 36
            defaultConfig { minSdk = 31 }
            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_21
                targetCompatibility = JavaVersion.VERSION_21
            }
            testOptions { unitTests { isIncludeAndroidResources = true } }
        }
        dependencies {
            add("implementation", libs.library("kotlinx-coroutines-core"))
            add("implementation", libs.library("kotlinx-serialization-json"))
            add("testImplementation", libs.library("junit"))
            add("testImplementation", libs.library("truth"))
            add("testImplementation", libs.library("turbine"))
            add("testImplementation", libs.library("kotlinx-coroutines-test"))
        }
    }
}
```

Register it in `app2/build-logic/convention/build.gradle.kts`, inside `gradlePlugin.plugins`:

```kotlin
        register("androidLibrary") {
            id = "shopnexus.android.library"
            implementationClass = "AndroidLibraryConventionPlugin"
        }
```

If the first build in Step 9 fails with `Inconsistent JVM-target compatibility detected for tasks 'compileDebugJavaWithJavac' (21) and 'compileDebugKotlin' (…)`, built-in Kotlin did not take its target from `compileOptions`. Then add `compileOnly("org.jetbrains.kotlin:kotlin-gradle-plugin-api:2.4.21")` to `build-logic/convention/build.gradle.kts` and, in this plugin and every Android plugin after it, add:

```kotlin
        extensions.configure<org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension> {
            compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21)
        }
```

- [ ] **Step 2: Write the failing money and time tests**

`app2/core/model/src/test/kotlin/vn/shopnexus/core/model/MoneyFormatTest.kt`:

```kotlin
package vn.shopnexus.core.model

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class MoneyFormatTest {
    @Test
    fun fullUsesDotsAndANonBreakingSpace() {
        assertThat(Vnd(10_900_000).full()).isEqualTo("10.900.000\u00A0₫")
        assertThat(Vnd(22_000).full()).isEqualTo("22.000\u00A0₫")
        assertThat(Vnd(0).full()).isEqualTo("0\u00A0₫")
    }

    @Test
    fun digitsDropTheUnit() {
        assertThat(Vnd(10_600_000).digits()).isEqualTo("10.600.000")
    }

    @Test
    fun shortUsesMillionsWithOneDecimal() {
        assertThat(Vnd(10_500_000).short()).isEqualTo("10,5 tr")
        assertThat(Vnd(4_000_000).short()).isEqualTo("4 tr")
        assertThat(Vnd(1_750_000).short()).isEqualTo("1,8 tr")
        assertThat(Vnd(385_000_000).short()).isEqualTo("385 tr")
        assertThat(Vnd(300_000).short()).isEqualTo("300.000")
    }

    @Test
    fun cardsShortenFromTenMillion() {
        assertThat(Vnd(10_900_000).cardParts()).isEqualTo("10,9" to " tr\u00A0₫")
        assertThat(Vnd(385_000_000).cardParts()).isEqualTo("385" to " tr\u00A0₫")
        assertThat(Vnd(4_800_000).cardParts()).isEqualTo("4.800.000" to "\u00A0₫")
    }
}
```

`app2/core/domain/src/test/kotlin/vn/shopnexus/core/domain/RelativeTimeTest.kt`:

```kotlin
package vn.shopnexus.core.domain

import com.google.common.truth.Truth.assertThat
import java.time.Instant
import org.junit.Test

class RelativeTimeTest {
    private val now = Instant.parse("2026-10-15T08:10:00Z") // 15:10 in Hồ Chí Minh City

    @Test
    fun labelsSayTodayTomorrowOrTheDate() {
        assertThat(meetingLabel(Instant.parse("2026-10-15T12:00:00Z"), now, VN_ZONE)).isEqualTo("19:00 hôm nay")
        assertThat(meetingLabel(Instant.parse("2026-10-16T12:00:00Z"), now, VN_ZONE)).isEqualTo("19:00 mai")
        assertThat(meetingLabel(Instant.parse("2026-10-17T11:30:00Z"), now, VN_ZONE)).isEqualTo("18:30 17/10")
    }

    @Test
    fun todayAtUsesTheLocalDay() {
        assertThat(todayAt(19, 0, now, VN_ZONE)).isEqualTo(Instant.parse("2026-10-15T12:00:00Z"))
    }
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `./gradlew :core:model:test :core:domain:test`
Expected: FAIL, `Unresolved reference 'full'` and `Unresolved reference 'meetingLabel'`.

- [ ] **Step 4: Write the money and time helpers**

`app2/core/model/src/main/kotlin/vn/shopnexus/core/model/MoneyFormat.kt`:

```kotlin
package vn.shopnexus.core.model

import java.math.BigDecimal
import java.math.RoundingMode

private const val NBSP = '\u00A0'

/** "10.900.000" */
fun Vnd.digits(): String = amount.toString().reversed().chunked(3).joinToString(".").reversed()

/** "10.900.000 ₫" */
fun Vnd.full(): String = "${digits()}$NBSP₫"

/** "10,9 tr" from a million up; smaller amounts stay in full digits. */
fun Vnd.short(): String {
    if (amount < 1_000_000) return digits()
    val millions = BigDecimal(amount).divide(BigDecimal(1_000_000), 1, RoundingMode.HALF_UP).stripTrailingZeros()
    return millions.toPlainString().replace('.', ',') + " tr"
}

/** A card price and its unit, shown one size down: "10,9" + " tr ₫" from 10 triệu up, else the full digits + " ₫". */
fun Vnd.cardParts(): Pair<String, String> =
    if (amount >= 10_000_000) short().removeSuffix(" tr") to " tr$NBSP₫" else digits() to "$NBSP₫"
```

`app2/core/domain/src/main/kotlin/vn/shopnexus/core/domain/RelativeTime.kt`:

```kotlin
package vn.shopnexus.core.domain

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

val VN_ZONE: ZoneId = ZoneId.of("Asia/Ho_Chi_Minh")
private val HOUR = DateTimeFormatter.ofPattern("HH:mm")
private val DAY = DateTimeFormatter.ofPattern("dd/MM")

/** How a meeting time reads in the app: "19:00 hôm nay", "19:00 mai", or with the date. */
fun meetingLabel(at: Instant, now: Instant, zone: ZoneId): String {
    val day = at.atZone(zone)
    val today = now.atZone(zone).toLocalDate()
    val hour = HOUR.format(day)
    return when (day.toLocalDate()) {
        today -> "$hour hôm nay"
        today.plusDays(1) -> "$hour mai"
        else -> "$hour ${DAY.format(day)}"
    }
}

fun todayAt(hour: Int, minute: Int, now: Instant, zone: ZoneId): Instant =
    now.atZone(zone).toLocalDate().atTime(hour, minute).atZone(zone).toInstant()
```

- [ ] **Step 5: Run them to verify they pass**

Run: `./gradlew :core:model:test :core:domain:test`
Expected: PASS.

- [ ] **Step 6: Create `:core:data` and `:core:testing`**

Add `include(":core:data", ":core:testing")` to `app2/settings.gradle.kts`.

`app2/core/data/build.gradle.kts`:

```kotlin
plugins {
    id("shopnexus.android.library")
}

android {
    namespace = "vn.shopnexus.core.data"
}

dependencies {
    api(project(":core:domain"))
    testImplementation(project(":core:testing"))
}
```

`app2/core/testing/build.gradle.kts`:

```kotlin
plugins {
    id("shopnexus.android.library")
}

android {
    namespace = "vn.shopnexus.core.testing"
}

dependencies {
    api(project(":core:data"))
    api(libs.junit)
    api(libs.kotlinx.coroutines.test)
    api(libs.turbine)
    api(libs.truth)
}
```

`app2/core/testing/src/main/kotlin/vn/shopnexus/core/testing/SchedulerClock.kt`:

```kotlin
package vn.shopnexus.core.testing

import java.time.Clock
import java.time.Instant
import java.time.ZoneId
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestCoroutineScheduler
import vn.shopnexus.core.data.fake.Fixtures
import vn.shopnexus.core.domain.VN_ZONE

/** A clock that moves with virtual time, so timestamps and delays agree in tests. */
@OptIn(ExperimentalCoroutinesApi::class)
class SchedulerClock(
    private val scheduler: TestCoroutineScheduler,
    private val start: Instant = Fixtures.NOW,
    private val zone: ZoneId = VN_ZONE,
) : Clock() {
    override fun instant(): Instant = start.plusMillis(scheduler.currentTime)
    override fun getZone(): ZoneId = zone
    override fun withZone(zone: ZoneId): Clock = SchedulerClock(scheduler, start, zone)
}
```

`app2/core/testing/src/main/kotlin/vn/shopnexus/core/testing/MainDispatcherRule.kt`:

```kotlin
package vn.shopnexus.core.testing

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestDispatcher
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.rules.TestWatcher
import org.junit.runner.Description

/** Runs `viewModelScope` on a test dispatcher. */
@OptIn(ExperimentalCoroutinesApi::class)
class MainDispatcherRule(val dispatcher: TestDispatcher = UnconfinedTestDispatcher()) : TestWatcher() {
    override fun starting(description: Description) = Dispatchers.setMain(dispatcher)
    override fun finished(description: Description) = Dispatchers.resetMain()
}
```

- [ ] **Step 7: Write the repository interfaces**

`app2/core/data/src/main/kotlin/vn/shopnexus/core/data/Repositories.kt`:

```kotlin
package vn.shopnexus.core.data

import kotlinx.coroutines.flow.Flow
import vn.shopnexus.core.model.ChatView
import vn.shopnexus.core.model.Deal
import vn.shopnexus.core.model.DealCommand
import vn.shopnexus.core.model.DealId
import vn.shopnexus.core.model.HomeFeed
import vn.shopnexus.core.model.ListingDetail
import vn.shopnexus.core.model.ListingId
import vn.shopnexus.core.model.ReportReason

/** Reads are one call per screen and fail by throwing from their flow; writes are commands that return the new state. */
interface HomeRepository {
    fun feed(): Flow<HomeFeed>

    /** Pulls new listings into "Gần bạn"; returns how many arrived. */
    suspend fun refresh(): Result<Int>
}

interface ListingRepository {
    /** Emits null when the listing does not exist. */
    fun detail(id: ListingId): Flow<ListingDetail?>
    suspend fun setSaved(id: ListingId, saved: Boolean): Result<Unit>
    suspend fun report(id: ListingId, reason: ReportReason): Result<Unit>
}

interface DealRepository {
    /** The open deal as a stream: a real backend serves it over SSE or a WebSocket. */
    fun chat(id: DealId): Flow<ChatView?>
    fun counterpartTyping(id: DealId): Flow<Boolean>
    suspend fun send(id: DealId, command: DealCommand): Result<Deal>
}

/** Reads the seller's code at a meet-up. CameraX and ML Kit replace the fake in stage 3. */
interface QrScanner {
    suspend fun scan(): Result<String>
}
```

- [ ] **Step 8: Add the fixtures and their loader**

Copy the four files below into `app2/core/data/src/main/resources/fixtures/`. They come from the mockup builders in `.superdesign/tools` (Home, Listing detail, Chat), so the app and the mockups show the same data.

`home.json`:

```json
{
  "district": "Bình Thạnh, TP.HCM",
  "searchHints": [
    "Tìm iPhone, xe đạp, sofa…",
    "“xe đạp đi làm dưới 3 triệu”",
    "“quà sinh nhật dưới 500k”"
  ],
  "hero": [
    {
      "imageUrl": "https://images.unsplash.com/photo-1583417319070-4a69db38a482?w=900&q=80&auto=format&fit=crop",
      "tag": "TP.HCM",
      "title": "Giá tốt, gần bạn, chốt nhanh",
      "cta": "Xem quanh đây"
    },
    {
      "imageUrl": "https://images.unsplash.com/photo-1517649763962-0c623066013b?w=900&q=80&auto=format&fit=crop",
      "tag": "Mùa đạp xe",
      "title": "Xe đạp cũ từ 1,5 triệu",
      "cta": "Xem xe đạp"
    },
    {
      "imageUrl": "https://images.unsplash.com/photo-1518455027359-f3f8164ba6bd?w=900&q=80&auto=format&fit=crop",
      "tag": "Góc làm việc",
      "title": "Setup bàn làm việc tiết kiệm",
      "cta": "Xem ngay"
    },
    {
      "imageUrl": "https://images.unsplash.com/photo-1559592413-7cec4d0cae2b?w=900&q=80&auto=format&fit=crop",
      "tag": "COD xem hàng",
      "title": "Xem hàng rồi mới trả, không ưng thì từ chối",
      "cta": "Tìm hiểu"
    }
  ],
  "categories": [
    {
      "key": "c0",
      "label": "Điện thoại",
      "icon": "phone_android",
      "shape": "Cookie9Sided"
    },
    {
      "key": "c1",
      "label": "Laptop",
      "icon": "laptop_chromebook",
      "shape": "Clover4Leaf"
    },
    {
      "key": "c2",
      "label": "Thời trang",
      "icon": "apparel",
      "shape": "Sunny"
    },
    {
      "key": "c3",
      "label": "Xe cộ",
      "icon": "two_wheeler",
      "shape": "Arch"
    },
    {
      "key": "c4",
      "label": "Nội thất",
      "icon": "chair",
      "shape": "Pill"
    },
    {
      "key": "c5",
      "label": "Đồ gia dụng",
      "icon": "blender",
      "shape": "Gem"
    },
    {
      "key": "c6",
      "label": "Mẹ & bé",
      "icon": "stroller",
      "shape": "Flower"
    },
    {
      "key": "c7",
      "label": "Thể thao",
      "icon": "sports_tennis",
      "shape": "SoftBurst"
    }
  ],
  "nearby": [
    {
      "id": "l-1510557880182",
      "photoUrl": "https://images.unsplash.com/photo-1510557880182-3d4d3cba35a5?w=480&q=80&auto=format&fit=crop",
      "price": 3900000,
      "title": "iPhone X 64GB, pin 86%, máy zin chưa sửa",
      "condition": "USED",
      "distanceKm": 0.6
    },
    {
      "id": "l-1591047139829",
      "photoUrl": "https://images.unsplash.com/photo-1591047139829-d91aecb6caea?w=480&q=80&auto=format&fit=crop",
      "price": 380000,
      "title": "Áo bomber màu bò size M, mặc 2 lần",
      "condition": "LIKE_NEW",
      "distanceKm": 0.9
    },
    {
      "id": "l-1585515320310",
      "photoUrl": "https://images.unsplash.com/photo-1585515320310-259814833e62?w=480&q=80&auto=format&fit=crop",
      "price": 450000,
      "title": "Máy xay sinh tố 2L, còn bảo hành 6 tháng",
      "condition": "USED",
      "distanceKm": 1.1
    },
    {
      "id": "l-1507035895480",
      "photoUrl": "https://images.unsplash.com/photo-1507035895480-2b3156c31fc8?w=480&q=80&auto=format&fit=crop",
      "price": 2300000,
      "title": "Xe đạp fixed gear khung thép, vừa thay lốp",
      "condition": "USED",
      "distanceKm": 1.4,
      "insight": {
        "direction": "CHEAPER",
        "percent": 10
      }
    },
    {
      "id": "l-1526170375885",
      "photoUrl": "https://images.unsplash.com/photo-1526170375885-4d8ecf77b99f?w=480&q=80&auto=format&fit=crop",
      "price": 1750000,
      "title": "Máy ảnh Polaroid OneStep 2, tặng 1 hộp film",
      "condition": "LIKE_NEW",
      "distanceKm": 1.8,
      "saved": true
    }
  ],
  "interests": [
    "Xe đạp",
    "Máy ảnh",
    "iPhone",
    "Nội thất gỗ"
  ],
  "forYou": [
    {
      "id": "p-iphone13",
      "photoUrl": "https://images.unsplash.com/photo-1632661674596-df8be070a5c5?w=480&h=480&fit=crop&crop=focalpoint&fp-x=0.5&fp-y=0.52&fp-z=1.25&q=80&auto=format",
      "price": 10900000,
      "title": "iPhone 13 Pro 128GB, Xanh Sierra, pin 88%",
      "condition": "LIKE_NEW",
      "distanceKm": 1.6,
      "insight": {
        "direction": "CHEAPER",
        "percent": 13
      }
    },
    {
      "id": "l-1695048133142",
      "photoUrl": "https://images.unsplash.com/photo-1695048133142-1a20484d2569?w=480&q=80&auto=format&fit=crop",
      "price": 15900000,
      "title": "iPhone 15 128GB, bảo hành Apple đến 03/2027",
      "condition": "LIKE_NEW",
      "distanceKm": 3.2,
      "insight": {
        "direction": "CHEAPER",
        "percent": 12
      }
    },
    {
      "id": "l-1611186871348",
      "photoUrl": "https://images.unsplash.com/photo-1611186871348-b1ce696e52c9?w=480&q=80&auto=format&fit=crop",
      "price": 11500000,
      "title": "MacBook Air M1 13 inch 8/256GB, sạc 92 lần",
      "condition": "USED",
      "distanceKm": 3.4
    },
    {
      "id": "l-1542291026",
      "photoUrl": "https://images.unsplash.com/photo-1542291026-7eec264c27ff?w=480&q=80&auto=format&fit=crop",
      "price": 1290000,
      "title": "Giày Nike Free RN size 42, mới nguyên hộp",
      "condition": "NEW",
      "distanceKm": 2.2,
      "saved": true
    },
    {
      "id": "l-1516035069371",
      "photoUrl": "https://images.unsplash.com/photo-1516035069371-29a1b244cc32?w=480&q=80&auto=format&fit=crop",
      "price": 26500000,
      "title": "Sony A7 III kèm lens 28-70 và 50mm f/1.8",
      "condition": "LIKE_NEW",
      "distanceKm": 4.0,
      "insight": {
        "direction": "CHEAPER",
        "percent": 18
      }
    },
    {
      "id": "l-1555041469",
      "photoUrl": "https://images.unsplash.com/photo-1555041469-a586c61ea9bc?w=480&q=80&auto=format&fit=crop",
      "price": 4800000,
      "title": "Sofa nhung xanh 3 chỗ, chuyển nhà cần bán gấp",
      "condition": "USED",
      "distanceKm": 6.8
    },
    {
      "id": "l-1609630875171",
      "photoUrl": "https://images.unsplash.com/photo-1609630875171-b1321377ee65?w=480&q=80&auto=format&fit=crop",
      "price": 385000000,
      "title": "Yamaha YZF-R1 2019, 8.000 km, chính chủ",
      "condition": "USED",
      "distanceKm": 9.2
    },
    {
      "id": "l-1505740420928",
      "photoUrl": "https://images.unsplash.com/photo-1505740420928-5e560c06d30e?w=480&q=80&auto=format&fit=crop",
      "price": 3200000,
      "title": "Tai nghe chống ồn Sony WH-1000XM4, fullbox",
      "condition": "LIKE_NEW",
      "distanceKm": 2.7
    },
    {
      "id": "l-1586023492125",
      "photoUrl": "https://images.unsplash.com/photo-1586023492125-27b2c045efd7?w=480&q=80&auto=format&fit=crop",
      "price": 1600000,
      "title": "Ghế bành bọc vải vàng mù tạt, khung gỗ sồi",
      "condition": "USED",
      "distanceKm": 5.5
    },
    {
      "id": "l-1580480055273",
      "photoUrl": "https://images.unsplash.com/photo-1580480055273-228ff5388ef8?w=480&q=80&auto=format&fit=crop",
      "price": 950000,
      "title": "Ghế xoay vải be chân gỗ, ngồi êm",
      "condition": "LIKE_NEW",
      "distanceKm": 3.9
    }
  ],
  "unreadNotifications": 4
}
```

`fresh.json`:

```json
[
  {
    "id": "l-1600294037681",
    "photoUrl": "https://images.unsplash.com/photo-1600294037681-c80b4cb5b434?w=480&q=80&auto=format&fit=crop",
    "price": 1100000,
    "title": "Tai nghe AirPods 2, tai trái hơi rè",
    "condition": "USED",
    "distanceKm": 0.4
  },
  {
    "id": "l-1593764592116",
    "photoUrl": "https://images.unsplash.com/photo-1593764592116-bfb2a97c642a?w=480&q=80&auto=format&fit=crop",
    "price": 1800000,
    "title": "Fixie đen mờ size 50, ít đi",
    "condition": "LIKE_NEW",
    "distanceKm": 0.7
  }
]
```

`listing-p-iphone13.json`:

```json
{
  "listing": {
    "id": "p-iphone13",
    "sellerId": "u-kiet",
    "title": "iPhone 13 Pro 128GB, Xanh Sierra, pin 88%",
    "price": 10900000,
    "categoryPath": [
      "Điện thoại",
      "iPhone"
    ],
    "condition": "LIKE_NEW",
    "declaredMarks": [
      {
        "text": "2 vết xước nhỏ ở viền",
        "closeUp": {
          "url": "https://images.unsplash.com/photo-1632661674596-df8be070a5c5?w=900&h=900&fit=crop&crop=focalpoint&fp-x=0.64&fp-y=0.56&fp-z=3.2&q=80&auto=format",
          "source": "APP",
          "capturedAt": "2026-10-12T12:30:00Z",
          "alt": "Cạnh viền"
        }
      }
    ],
    "photos": [
      {
        "url": "https://images.unsplash.com/photo-1632661674596-df8be070a5c5?w=900&h=900&fit=crop&crop=focalpoint&fp-x=0.5&fp-y=0.52&fp-z=1.25&q=80&auto=format",
        "source": "APP",
        "capturedAt": "2026-10-12T12:30:00Z",
        "alt": "Mặt lưng máy"
      },
      {
        "url": "https://images.unsplash.com/photo-1632661674596-df8be070a5c5?w=900&h=900&fit=crop&crop=focalpoint&fp-x=0.48&fp-y=0.42&fp-z=3.4&q=80&auto=format",
        "source": "APP",
        "capturedAt": "2026-10-12T12:30:00Z",
        "alt": "Cụm camera"
      },
      {
        "url": "https://images.unsplash.com/photo-1632661674596-df8be070a5c5?w=900&h=900&fit=crop&crop=focalpoint&fp-x=0.53&fp-y=0.56&fp-z=2.1&q=80&auto=format",
        "source": "APP",
        "capturedAt": "2026-10-12T12:30:00Z",
        "alt": "Mặt lưng và logo"
      },
      {
        "url": "https://images.unsplash.com/photo-1632661674596-df8be070a5c5?w=900&h=900&fit=crop&crop=focalpoint&fp-x=0.64&fp-y=0.56&fp-z=3.2&q=80&auto=format",
        "source": "APP",
        "capturedAt": "2026-10-12T12:30:00Z",
        "alt": "Cạnh viền"
      }
    ],
    "specs": [
      {
        "label": "Dòng máy",
        "value": "iPhone 13 Pro"
      },
      {
        "label": "Dung lượng",
        "value": "128 GB"
      },
      {
        "label": "Màu",
        "value": "Xanh Sierra"
      },
      {
        "label": "Pin",
        "value": "88%"
      },
      {
        "label": "Phiên bản",
        "value": "VN/A"
      },
      {
        "label": "Bảo hành",
        "value": "Đã hết"
      },
      {
        "label": "Sửa chữa",
        "value": "Chưa từng"
      },
      {
        "label": "Phụ kiện",
        "value": "Cáp sạc, ốp lưng"
      }
    ],
    "description": "Mình dùng từ 2022, máy zin chưa sửa chữa, Face ID nhạy. Viền có 2 vết xước nhỏ, mặt lưng đẹp vì luôn đeo ốp. Đổi máy nên bán lại.\n\nXem máy trực tiếp quanh Bình Thạnh, buổi tối sau 18h.",
    "district": "Bình Thạnh",
    "distanceKm": 1.6,
    "paths": [
      "MEET"
    ],
    "allowOffers": true,
    "postedAt": "2026-10-15T05:10:00Z",
    "meetNote": "Bình Thạnh · sau 18:00"
  },
  "seller": {
    "id": "u-kiet",
    "name": "Tuấn Kiệt",
    "avatarUrl": "https://images.unsplash.com/photo-1544723795-3fb6469f5b39?w=120&q=80&auto=format&fit=crop",
    "verified": true,
    "tier": "TOP",
    "rating": 4.9,
    "ratingCount": 32,
    "sold": 14,
    "replyTime": "10 phút",
    "joinedYear": 2023
  },
  "insight": {
    "direction": "CHEAPER",
    "percent": 13,
    "range": {
      "low": 11800000,
      "median": 12500000,
      "high": 13200000
    },
    "sampleSize": 42,
    "windowDays": 30,
    "area": "TP.HCM"
  },
  "similar": [
    {
      "id": "p-iphone14",
      "photoUrl": "https://images.unsplash.com/photo-1663499482523-1c0c1bae4ce1?w=480&q=80&auto=format&fit=crop",
      "price": 12800000,
      "title": "iPhone 14 128GB",
      "condition": "LIKE_NEW",
      "distanceKm": 4.4
    },
    {
      "id": "p-iphone12",
      "photoUrl": "https://images.unsplash.com/photo-1616348436168-de43ad0db179?w=480&q=80&auto=format&fit=crop",
      "price": 6900000,
      "title": "iPhone 12 128GB",
      "condition": "USED",
      "distanceKm": 0.8
    },
    {
      "id": "p-s23",
      "photoUrl": "https://images.unsplash.com/photo-1678911820864-e2c567c655d7?w=480&q=80&auto=format&fit=crop",
      "price": 14500000,
      "title": "Galaxy S23 Ultra 256GB",
      "condition": "LIKE_NEW",
      "distanceKm": 2.9
    },
    {
      "id": "p-mini",
      "photoUrl": "https://images.unsplash.com/photo-1580910051074-3eb694886505?w=480&q=80&auto=format&fit=crop",
      "price": 5200000,
      "title": "iPhone 12 mini 64GB",
      "condition": "USED",
      "distanceKm": 1.9
    }
  ],
  "saved": false,
  "questions": [
    "Máy còn không bạn?",
    "Xem máy ở đâu được?",
    "Có hộp và hóa đơn không?"
  ],
  "suggestedOffers": [
    10600000,
    10400000,
    10000000,
    9800000
  ],
  "deal": {
    "id": "d-kiet",
    "counter": 10600000
  }
}
```

`chat-d-kiet.json`:

```json
{
  "deal": {
    "id": "d-kiet",
    "listingId": "p-iphone13",
    "buyerId": "u-linh",
    "sellerId": "u-kiet",
    "listedPrice": 10900000,
    "path": "MEET",
    "stage": "NEGOTIATE",
    "offers": [
      {
        "by": "BUYER",
        "amount": 10400000,
        "at": "2026-10-15T07:08:00Z",
        "status": "SUPERSEDED"
      },
      {
        "by": "SELLER",
        "amount": 10600000,
        "at": "2026-10-15T07:10:00Z",
        "status": "OPEN"
      }
    ],
    "meetPoints": [
      {
        "name": "Sảnh Landmark 81",
        "why": "Có bảo vệ, đông người"
      },
      {
        "name": "Highlands Phan Xích Long",
        "why": "Quán đông, có camera"
      },
      {
        "name": "Trụ sở Công an phường 22",
        "why": "Điểm hẹn an toàn"
      }
    ],
    "checklist": [
      {
        "id": "k0",
        "text": "Face ID mở được máy",
        "icon": "familiar_face_and_zone",
        "checked": false
      },
      {
        "id": "k1",
        "text": "Pin từ 88% (Cài đặt › Pin)",
        "icon": "battery_full_alt",
        "checked": false
      },
      {
        "id": "k2",
        "text": "Đã thoát iCloud, tắt Tìm iPhone",
        "icon": "cloud_off",
        "checked": false
      },
      {
        "id": "k3",
        "text": "IMEI trong máy trùng hộp",
        "icon": "pin",
        "checked": false
      },
      {
        "id": "k4",
        "text": "Camera, loa, mic chạy tốt",
        "icon": "photo_camera",
        "checked": false
      },
      {
        "id": "k5",
        "text": "Màn hình không điểm chết",
        "icon": "mobile",
        "checked": false
      }
    ],
    "priceInsight": {
      "direction": "CHEAPER",
      "percent": 15
    },
    "thread": [
      {
        "type": "text",
        "by": "BUYER",
        "text": "Chào bạn, máy còn không ạ?",
        "at": "2026-10-15T07:02:00Z"
      },
      {
        "type": "text",
        "by": "SELLER",
        "text": "Còn bạn nhé.",
        "at": "2026-10-15T07:05:00Z"
      },
      {
        "type": "text",
        "by": "SELLER",
        "text": "Máy zin, pin 88%, chưa sửa gì. Mình chụp thêm cạnh viền cho bạn xem.",
        "at": "2026-10-15T07:05:00Z"
      },
      {
        "type": "photos",
        "by": "SELLER",
        "urls": [
          "https://images.unsplash.com/photo-1632661674596-df8be070a5c5?w=480&h=480&fit=crop&crop=focalpoint&fp-x=0.64&fp-y=0.56&fp-z=3.2&q=80&auto=format",
          "https://images.unsplash.com/photo-1632661674596-df8be070a5c5?w=480&h=480&fit=crop&crop=focalpoint&fp-x=0.48&fp-y=0.42&fp-z=3.4&q=80&auto=format"
        ],
        "at": "2026-10-15T07:05:00Z"
      },
      {
        "type": "priceMove",
        "by": "BUYER",
        "amount": 10400000,
        "accepted": false,
        "at": "2026-10-15T07:08:00Z"
      },
      {
        "type": "text",
        "by": "BUYER",
        "text": "Bạn đồng ý thì mình lấy luôn nhé.",
        "at": "2026-10-15T07:08:00Z"
      },
      {
        "type": "text",
        "by": "SELLER",
        "text": "10,4 thì hơi thấp bạn ơi. 10,6 mình bán liền, tặng thêm ốp.",
        "at": "2026-10-15T07:10:00Z"
      },
      {
        "type": "priceMove",
        "by": "SELLER",
        "amount": 10600000,
        "accepted": false,
        "at": "2026-10-15T07:10:00Z"
      }
    ],
    "counterExpiresAt": "2026-10-16T07:10:00Z"
  },
  "listing": {
    "id": "p-iphone13",
    "photoUrl": "https://images.unsplash.com/photo-1632661674596-df8be070a5c5?w=480&h=480&fit=crop&crop=focalpoint&fp-x=0.5&fp-y=0.52&fp-z=1.25&q=80&auto=format",
    "price": 10900000,
    "title": "iPhone 13 Pro 128GB, Xanh Sierra, pin 88%",
    "condition": "LIKE_NEW",
    "distanceKm": 1.6,
    "insight": {
      "direction": "CHEAPER",
      "percent": 13
    }
  },
  "counterpart": {
    "id": "u-kiet",
    "name": "Tuấn Kiệt",
    "avatarUrl": "https://images.unsplash.com/photo-1544723795-3fb6469f5b39?w=120&q=80&auto=format&fit=crop",
    "verified": true,
    "tier": "TOP",
    "rating": 4.9,
    "ratingCount": 32,
    "sold": 14,
    "replyTime": "10 phút",
    "joinedYear": 2023
  },
  "me": {
    "id": "u-linh",
    "name": "Khánh Linh",
    "avatarUrl": "https://images.unsplash.com/photo-1541823709867-1b206113eafd?w=120&q=80&auto=format&fit=crop",
    "district": "Bình Thạnh"
  },
  "declaredMarks": [
    {
      "text": "2 vết xước nhỏ ở viền",
      "closeUp": {
        "url": "https://images.unsplash.com/photo-1632661674596-df8be070a5c5?w=900&h=900&fit=crop&crop=focalpoint&fp-x=0.64&fp-y=0.56&fp-z=3.2&q=80&auto=format",
        "source": "APP",
        "capturedAt": "2026-10-12T12:30:00Z",
        "alt": "Cạnh viền"
      }
    }
  ]
}
```

`app2/core/data/src/main/kotlin/vn/shopnexus/core/data/fake/Fixtures.kt`:

```kotlin
package vn.shopnexus.core.data.fake

import java.time.Clock
import java.time.Duration
import java.time.Instant
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.ListSerializer
import vn.shopnexus.core.domain.VN_ZONE
import vn.shopnexus.core.model.ChatView
import vn.shopnexus.core.model.HomeFeed
import vn.shopnexus.core.model.ListingDetail
import vn.shopnexus.core.model.ListingSummary
import vn.shopnexus.core.model.ShopNexusJson

/** The mockups' data, read from `resources/fixtures`. */
object Fixtures {
    /** The moment the fixtures describe: 15:10 on 15/10/2026 in Hồ Chí Minh City. */
    val NOW: Instant = Instant.parse("2026-10-15T08:10:00Z")

    fun home(): HomeFeed = read("home", HomeFeed.serializer())
    fun fresh(): List<ListingSummary> = read("fresh", ListSerializer(ListingSummary.serializer()))
    fun detail(id: String): ListingDetail = read("listing-$id", ListingDetail.serializer())
    fun chat(id: String): ChatView = read("chat-$id", ChatView.serializer())

    private fun <T> read(name: String, serializer: KSerializer<T>): T {
        val stream = requireNotNull(Fixtures::class.java.classLoader?.getResourceAsStream("fixtures/$name.json")) {
            "Missing fixture fixtures/$name.json"
        }
        return stream.use { ShopNexusJson.decodeFromString(serializer, it.readBytes().decodeToString()) }
    }
}

/** A clock that starts at [Fixtures.NOW] and runs in real time, so "hôm nay" and countdowns match the data. */
fun fixtureClock(base: Clock = Clock.systemUTC()): Clock =
    Clock.offset(base, Duration.between(base.instant(), Fixtures.NOW)).withZone(VN_ZONE)
```

- [ ] **Step 9: Write the fixtures test**

`app2/core/data/src/test/kotlin/vn/shopnexus/core/data/fake/FixturesTest.kt`:

```kotlin
package vn.shopnexus.core.data.fake

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Test
import vn.shopnexus.core.model.DealStage
import vn.shopnexus.core.model.ListingId
import vn.shopnexus.core.model.Vnd

class FixturesTest {
    @Test
    fun homeMatchesTheMockup() {
        val home = Fixtures.home()
        assertThat(home.district).isEqualTo("Bình Thạnh, TP.HCM")
        assertThat(home.hero).hasSize(4)
        assertThat(home.categories).hasSize(8)
        assertThat(home.nearby.first().title).startsWith("iPhone X 64GB")
        assertThat(home.forYou.first().id).isEqualTo(ListingId("p-iphone13"))
        assertThat(Fixtures.fresh()).hasSize(2)
    }

    @Test
    fun detailAndChatAgreeOnTheDeal() {
        val detail = Fixtures.detail("p-iphone13")
        val chat = Fixtures.chat("d-kiet")
        assertThat(detail.listing.price).isEqualTo(Vnd(10_900_000))
        assertThat(detail.insight?.range?.median).isEqualTo(Vnd(12_500_000))
        assertThat(detail.deal?.counter).isEqualTo(Vnd(10_600_000))
        assertThat(chat.deal.openCounter?.amount).isEqualTo(Vnd(10_600_000))
        assertThat(chat.deal.stage).isEqualTo(DealStage.NEGOTIATE)
        assertThat(chat.deal.thread).hasSize(8)
        assertThat(chat.deal.checklist).hasSize(6)
        assertThat(chat.deal.meetPoints.map { it.name }).containsExactly(
            "Sảnh Landmark 81", "Highlands Phan Xích Long", "Trụ sở Công an phường 22").inOrder()
    }

    @Test
    fun theFixtureClockStartsAtTheFixtureMoment() {
        val base = Clock.fixed(Instant.parse("2030-01-01T00:00:00Z"), ZoneOffset.UTC)
        val clock = fixtureClock(base)
        assertThat(Duration.between(Fixtures.NOW, clock.instant()).abs()).isLessThan(Duration.ofSeconds(1))
        assertThat(clock.zone.id).isEqualTo("Asia/Ho_Chi_Minh")
    }
}
```

Run: `./gradlew :core:data:testDebugUnitTest`
Expected: PASS, 3 tests.

- [ ] **Step 10: Commit**

```bash
git add build-logic settings.gradle.kts core
git commit -m "feat(data): add repository contracts, the mockup fixtures and the fixture clock

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: The fake world and fake repositories

`FakeWorld` holds every piece of state in one `StateFlow`; each fake repository is a view over it, so a change made on one screen shows on every other. `FakeDealEngine` is the server side of buyer commands. `FailurePolicy` makes calls slow or failing on purpose.

**Files:**
- Create in `app2/core/data/src/main/kotlin/vn/shopnexus/core/data/fake/`: `FakeWorld.kt`, `FailurePolicy.kt`, `FakeDealEngine.kt`, `CounterpartListener.kt`, `FakeHomeRepository.kt`, `FakeListingRepository.kt`, `FakeDealRepository.kt`, `FakeQrScanner.kt`
- Test: `app2/core/data/src/test/kotlin/vn/shopnexus/core/data/fake/FakeRepositoriesTest.kt`
- Test: `app2/core/data/src/test/kotlin/vn/shopnexus/core/data/fake/FakeDealEngineTest.kt`

**Interfaces:**
- Consumes: Task 10 contracts and helpers; `offerRange`, `OfferCheck` (Task 5).
- Produces:
  ```kotlin
  data class WorldState(val home: HomeFeed, val fresh: List<ListingSummary>, val details: Map<ListingId, ListingDetail>,
                        val chats: Map<DealId, ChatView>, val saved: Set<ListingId>, val typing: Set<DealId> = emptySet())
  class FakeWorld { val flow: StateFlow<WorldState>; val value: WorldState; fun update(f: (WorldState) -> WorldState); fun reset()
                    companion object { fun initial(): WorldState } }
  class FailurePolicy(var rate: Double = 0.0, var latencyMillis: Long = 300, private val random: Random = Random.Default) {
      suspend fun <T> run(block: () -> T): Result<T> }   // fails with FakeNetworkException
  class FakeNetworkException : IOException
  class FakeDealEngine(zone: ZoneId) { fun apply(view: ChatView, command: DealCommand, now: Instant): Deal }
  fun interface CounterpartListener { fun onCommand(id: DealId, command: DealCommand) }
  class FakeHomeRepository(world, failures) : HomeRepository
  class FakeListingRepository(world, failures) : ListingRepository
  class FakeDealRepository(world, failures, engine, clock, counterpart) : DealRepository
  class FakeQrScanner : QrScanner   // returns "SNX-KIET" after 1.6 s
  ```

- [ ] **Step 1: Write the failing tests**

`FakeDealEngineTest.kt`:

```kotlin
package vn.shopnexus.core.data.fake

import com.google.common.truth.Truth.assertThat
import java.time.Instant
import org.junit.Assert.assertThrows
import org.junit.Test
import vn.shopnexus.core.domain.VN_ZONE
import vn.shopnexus.core.model.DealCommand
import vn.shopnexus.core.model.DealStage
import vn.shopnexus.core.model.MeetPoint
import vn.shopnexus.core.model.MilestoneKind
import vn.shopnexus.core.model.OfferStatus
import vn.shopnexus.core.model.Party
import vn.shopnexus.core.model.RecordStatus
import vn.shopnexus.core.model.ThreadItem
import vn.shopnexus.core.model.Vnd

class FakeDealEngineTest {
    private val engine = FakeDealEngine(VN_ZONE)
    private val now = Fixtures.NOW
    private val start = Fixtures.chat("d-kiet")

    @Test
    fun anOfferBelowTheCounterIsAddedToTheThread() {
        val deal = engine.apply(start, DealCommand.SendOffer(Vnd(10_500_000), null), now)
        assertThat(deal.openOffer?.amount).isEqualTo(Vnd(10_500_000))
        assertThat(deal.thread.last()).isEqualTo(ThreadItem.PriceMove(Party.BUYER, Vnd(10_500_000), false, now))
    }

    @Test
    fun aMessageIsAddedTrimmedAndAnEmptyOneIsRefused() {
        val deal = engine.apply(start, DealCommand.SendText("  Máy còn không bạn? "), now)
        assertThat(deal.thread.last()).isEqualTo(ThreadItem.Text(Party.BUYER, "Máy còn không bạn?", now))
        assertThrows(IllegalArgumentException::class.java) { engine.apply(start, DealCommand.SendText("   "), now) }
    }

    @Test
    fun anOfferAtTheCounterIsRefused() {
        assertThrows(IllegalArgumentException::class.java) {
            engine.apply(start, DealCommand.SendOffer(Vnd(10_600_000), null), now)
        }
    }

    @Test
    fun acceptingTheCounterAgreesThePriceAndDrawsTheMilestone() {
        val deal = engine.apply(start, DealCommand.AcceptCounter, now)
        assertThat(deal.stage).isEqualTo(DealStage.ARRANGE)
        assertThat(deal.agreedPrice).isEqualTo(Vnd(10_600_000))
        assertThat(deal.offers.last().status).isEqualTo(OfferStatus.ACCEPTED)
        assertThat(deal.thread.last()).isEqualTo(ThreadItem.Milestone(MilestoneKind.AGREED, now))
    }

    @Test
    fun theWholeInPersonFlowEndsDone() {
        var view = start
        fun go(command: DealCommand) { view = view.copy(deal = engine.apply(view, command, now)) }
        go(DealCommand.AcceptCounter)
        go(DealCommand.ProposeMeeting(Instant.parse("2026-10-15T13:00:00Z"), MeetPoint("Highlands Phan Xích Long", "Quán đông, có camera")))
        assertThat((view.deal.thread.last() as ThreadItem.Text).text).isEqualTo("Mình đổi sang 20:00 hôm nay · Highlands Phan Xích Long được không bạn?")
        assertThrows(IllegalStateException::class.java) { engine.apply(view, DealCommand.ConfirmMeeting, now) }
        // The seller agrees (the Simulator's part), then the buyer is at the meeting.
        view = view.copy(deal = view.deal.copy(meeting = view.deal.meeting!!.copy(proposedBy = Party.SELLER)))
        go(DealCommand.ConfirmMeeting)
        assertThat(view.deal.stage).isEqualTo(DealStage.HANDOVER)
        go(DealCommand.SetCheck("k0", true))
        assertThat(view.deal.checklist.count { it.checked }).isEqualTo(1)
        go(DealCommand.RecordHandover("SNX-KIET"))
        assertThat(view.deal.stage).isEqualTo(DealStage.RATE)
        assertThat(view.deal.handedOverAt).isEqualTo(now)
        go(DealCommand.Rate(5))
        assertThat(view.deal.stage).isEqualTo(DealStage.DONE)
        go(DealCommand.OpenRecord("https://x/crack.jpg", "Mặt lưng có vết nứt nhỏ"))
        assertThat(view.deal.records.single().status).isEqualTo(RecordStatus.OPEN)
        assertThat(view.deal.records.single().aiNote).isEqualTo("Tin đã khai 2 vết xước nhỏ ở viền. Vết khác chưa có trong ảnh và mô tả của tin.")
    }

    @Test
    fun commandsOutOfOrderAreRefused() {
        assertThrows(IllegalStateException::class.java) { engine.apply(start, DealCommand.RecordHandover("SNX-KIET"), now) }
        assertThrows(IllegalStateException::class.java) { engine.apply(start, DealCommand.Rate(5), now) }
    }
}
```

`FakeRepositoriesTest.kt`:

```kotlin
package vn.shopnexus.core.data.fake

import app.cash.turbine.test
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Test
import vn.shopnexus.core.domain.VN_ZONE
import vn.shopnexus.core.model.DealCommand
import vn.shopnexus.core.model.DealId
import vn.shopnexus.core.model.ListingId
import vn.shopnexus.core.model.Vnd
import vn.shopnexus.core.testing.SchedulerClock

class FakeRepositoriesTest {
    private val world = FakeWorld()
    private val failures = FailurePolicy(latencyMillis = 0)
    private val iphone = ListingId("p-iphone13")

    @Test
    fun refreshBringsTwoListingsOnceThenNone() = runTest {
        val home = FakeHomeRepository(world, failures)
        assertThat(home.refresh().getOrThrow()).isEqualTo(2)
        assertThat(home.feed().first().nearby.first().title).startsWith("Tai nghe AirPods 2")
        assertThat(home.refresh().getOrThrow()).isEqualTo(0)
    }

    @Test
    fun savingOnHomeShowsOnListingDetail() = runTest {
        val listings = FakeListingRepository(world, failures)
        val home = FakeHomeRepository(world, failures)
        listings.detail(iphone).test {
            assertThat(awaitItem()!!.saved).isFalse()
            listings.setSaved(iphone, true)
            assertThat(awaitItem()!!.saved).isTrue()
        }
        assertThat(home.feed().first().forYou.first { it.id == iphone }.saved).isTrue()
    }

    @Test
    fun aCommandUpdatesTheChatAndTellsTheCounterpart() = runTest {
        val heard = mutableListOf<DealCommand>()
        val deals = FakeDealRepository(world, failures, FakeDealEngine(VN_ZONE), SchedulerClock(testScheduler)) { _, c -> heard += c }
        val id = DealId("d-kiet")
        deals.send(id, DealCommand.SendOffer(Vnd(10_500_000), null)).getOrThrow()
        assertThat(deals.chat(id).first()!!.deal.openOffer?.amount).isEqualTo(Vnd(10_500_000))
        assertThat(heard).containsExactly(DealCommand.SendOffer(Vnd(10_500_000), null))
        val ref = FakeListingRepository(world, failures).detail(iphone).first()!!.deal
        assertThat(ref?.counter).isEqualTo(Vnd(10_600_000))
        assertThat(ref?.myOffer).isEqualTo(Vnd(10_500_000))
    }

    @Test
    fun aFailedReadThrowsFromTheFlow() = runTest {
        val error = runCatching { FakeHomeRepository(world, FailurePolicy(rate = 1.0, latencyMillis = 0)).feed().first() }.exceptionOrNull()
        assertThat(error).isInstanceOf(FakeNetworkException::class.java)
    }

    @Test
    fun aFailedCommandChangesNothing() = runTest {
        val deals = FakeDealRepository(world, FailurePolicy(rate = 1.0, latencyMillis = 0), FakeDealEngine(VN_ZONE), SchedulerClock(testScheduler)) { _, _ -> }
        val before = world.value
        val result = deals.send(DealId("d-kiet"), DealCommand.AcceptCounter)
        assertThat(result.exceptionOrNull()).isInstanceOf(FakeNetworkException::class.java)
        assertThat(world.value).isEqualTo(before)
    }

    @Test
    fun aMissingListingIsNull() = runTest {
        assertThat(FakeListingRepository(world, failures).detail(ListingId("nope")).first()).isNull()
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `./gradlew :core:data:testDebugUnitTest`
Expected: FAIL, `Unresolved reference 'FakeWorld'`.

- [ ] **Step 3: Write the world, the failure policy and the counterpart hook**

`FakeWorld.kt`:

```kotlin
package vn.shopnexus.core.data.fake

import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import vn.shopnexus.core.model.ChatView
import vn.shopnexus.core.model.DealId
import vn.shopnexus.core.model.HomeFeed
import vn.shopnexus.core.model.ListingDetail
import vn.shopnexus.core.model.ListingId
import vn.shopnexus.core.model.ListingSummary

data class WorldState(
    val home: HomeFeed,
    val fresh: List<ListingSummary>,
    val details: Map<ListingId, ListingDetail>,
    val chats: Map<DealId, ChatView>,
    val saved: Set<ListingId>,
    val typing: Set<DealId> = emptySet(),
)

/** All fake state in one place; every fake repository reads and writes through it. */
@Singleton
class FakeWorld @Inject constructor() {
    private val state = MutableStateFlow(initial())
    val flow: StateFlow<WorldState> = state.asStateFlow()
    val value: WorldState get() = state.value

    fun update(f: (WorldState) -> WorldState) = state.update(f)
    fun reset() { state.value = initial() }

    companion object {
        fun initial(): WorldState {
            val home = Fixtures.home()
            val detail = Fixtures.detail("p-iphone13")
            val chat = Fixtures.chat("d-kiet")
            val saved = (home.nearby + home.forYou).filter { it.saved }.map { it.id }.toSet()
            return WorldState(
                home = home,
                fresh = Fixtures.fresh(),
                details = mapOf(detail.listing.id to detail),
                chats = mapOf(chat.deal.id to chat),
                saved = saved,
            )
        }
    }
}
```

`FailurePolicy.kt`:

```kotlin
package vn.shopnexus.core.data.fake

import java.io.IOException
import kotlin.random.Random
import kotlinx.coroutines.delay

class FakeNetworkException : IOException("Mạng giả lập bị lỗi")

/** Every fake call waits [latencyMillis] and fails with probability [rate]; the debug panel sets both. Hilt provides it from `DataModule`. */
class FailurePolicy(
    var rate: Double = 0.0,
    var latencyMillis: Long = 300,
    private val random: Random = Random.Default,
) {
    suspend fun <T> run(block: () -> T): Result<T> {
        if (latencyMillis > 0) delay(latencyMillis)
        if (rate > 0 && random.nextDouble() < rate) return Result.failure(FakeNetworkException())
        return runCatching(block)
    }
}
```

`CounterpartListener.kt`:

```kotlin
package vn.shopnexus.core.data.fake

import vn.shopnexus.core.model.DealCommand
import vn.shopnexus.core.model.DealId

/** Hears every buyer command, so the other side can react (the Simulator, Task 12). */
fun interface CounterpartListener {
    fun onCommand(id: DealId, command: DealCommand)
}
```

- [ ] **Step 4: Write the engine**

`FakeDealEngine.kt`:

```kotlin
package vn.shopnexus.core.data.fake

import java.time.Instant
import java.time.ZoneId
import javax.inject.Inject
import vn.shopnexus.core.domain.OfferCheck
import vn.shopnexus.core.domain.meetingLabel
import vn.shopnexus.core.domain.offerRange
import vn.shopnexus.core.model.ChatView
import vn.shopnexus.core.model.Deal
import vn.shopnexus.core.model.DealCommand
import vn.shopnexus.core.model.DealStage
import vn.shopnexus.core.model.IncidentRecord
import vn.shopnexus.core.model.Meeting
import vn.shopnexus.core.model.MilestoneKind
import vn.shopnexus.core.model.Offer
import vn.shopnexus.core.model.OfferStatus
import vn.shopnexus.core.model.Party
import vn.shopnexus.core.model.RecordId
import vn.shopnexus.core.model.RecordStatus
import vn.shopnexus.core.model.ThreadItem
import vn.shopnexus.core.model.full

/** What the backend does with a buyer command. Wrong amounts and out-of-order commands are refused. */
class FakeDealEngine @Inject constructor(private val zone: ZoneId) {
    fun apply(view: ChatView, command: DealCommand, now: Instant): Deal {
        val deal = view.deal
        fun label(meeting: Meeting) = meetingLabel(meeting.at, now, zone)
        return when (command) {
            is DealCommand.SendText -> {
                require(command.text.isNotBlank() && command.text.length <= 1000) { "A message is 1 to 1000 characters" }
                deal.copy(thread = deal.thread + ThreadItem.Text(Party.BUYER, command.text.trim(), now))
            }
            is DealCommand.SendOffer -> {
                check(deal.stage == DealStage.NEGOTIATE && deal.openOffer == null) { "No offer can be made now" }
                val range = offerRange(deal.listedPrice, deal.openCounter?.amount)
                require(range.check(command.amount) is OfferCheck.Ok) { "Offer ${command.amount} is outside $range" }
                deal.copy(
                    offers = deal.offers + Offer(Party.BUYER, command.amount, now, OfferStatus.OPEN),
                    thread = deal.thread + ThreadItem.PriceMove(Party.BUYER, command.amount, false, now) +
                        listOfNotNull(command.note?.let { ThreadItem.Text(Party.BUYER, it, now) }),
                )
            }
            DealCommand.AcceptCounter -> {
                check(deal.stage == DealStage.NEGOTIATE) { "Nothing to accept" }
                val counter = checkNotNull(deal.openCounter) { "No counter to accept" }
                deal.copy(
                    stage = DealStage.ARRANGE,
                    agreedPrice = counter.amount,
                    offers = deal.offers.map {
                        when {
                            it == counter -> it.copy(status = OfferStatus.ACCEPTED)
                            it.status == OfferStatus.OPEN -> it.copy(status = OfferStatus.SUPERSEDED)
                            else -> it
                        }
                    },
                    thread = deal.thread + ThreadItem.PriceMove(Party.BUYER, counter.amount, true, now) +
                        ThreadItem.Milestone(MilestoneKind.AGREED, now),
                )
            }
            DealCommand.WithdrawOffer -> {
                val open = checkNotNull(deal.openOffer) { "No offer to withdraw" }
                deal.copy(
                    offers = deal.offers.map { if (it == open) it.copy(status = OfferStatus.WITHDRAWN) else it },
                    thread = deal.thread + ThreadItem.Event("undo", "Bạn đã rút đề nghị", now),
                )
            }
            is DealCommand.ProposeMeeting -> {
                check(deal.stage == DealStage.ARRANGE) { "No meeting to arrange" }
                val meeting = Meeting(command.at, command.place, Party.BUYER, confirmed = false)
                deal.copy(
                    meeting = meeting,
                    thread = deal.thread + ThreadItem.Text(Party.BUYER, "Mình đổi sang ${label(meeting)} · ${command.place.name} được không bạn?", now),
                )
            }
            DealCommand.ConfirmMeeting -> {
                check(deal.stage == DealStage.ARRANGE) { "No meeting to confirm" }
                val proposed = checkNotNull(deal.meeting) { "No meeting proposed" }
                check(proposed.proposedBy == Party.SELLER) { "The buyer confirms the seller's proposal, not their own" }
                val meeting = proposed.copy(confirmed = true)
                deal.copy(
                    stage = DealStage.HANDOVER,
                    meeting = meeting,
                    thread = deal.thread + ThreadItem.Event("event_available", "Đã hẹn ${label(meeting)} · ${meeting.place.name}", now),
                )
            }
            is DealCommand.SetCheck -> {
                check(deal.stage == DealStage.HANDOVER) { "Nothing to check now" }
                deal.copy(checklist = deal.checklist.map { if (it.id == command.itemId) it.copy(checked = command.checked) else it })
            }
            is DealCommand.RecordHandover -> {
                check(deal.stage == DealStage.HANDOVER) { "No hand-over to record" }
                require(command.code.isNotBlank()) { "Empty code" }
                deal.copy(
                    stage = DealStage.RATE,
                    handedOverAt = now,
                    thread = deal.thread + ThreadItem.Milestone(MilestoneKind.HANDED_OVER, now),
                )
            }
            is DealCommand.Rate -> {
                check(deal.stage == DealStage.RATE) { "Nothing to rate" }
                require(command.stars in 1..5) { "Stars must be 1 to 5" }
                deal.copy(
                    stage = DealStage.DONE,
                    rating = command.stars,
                    thread = deal.thread + ThreadItem.Event("star", "${command.stars} sao cho ${view.counterpart.name}", now) +
                        ThreadItem.Milestone(MilestoneKind.RATED, now),
                )
            }
            is DealCommand.OpenRecord -> {
                check(deal.stage == DealStage.RATE || deal.stage == DealStage.DONE) { "Records open after the hand-over" }
                val id = RecordId("r${deal.records.size + 1}")
                val note = "Tin đã khai ${view.declaredMarks.joinToString { it.text }}. Vết khác chưa có trong ảnh và mô tả của tin."
                deal.copy(
                    records = deal.records + IncidentRecord(id, Party.BUYER, command.photoUrl, command.text, note, RecordStatus.OPEN),
                    thread = deal.thread + ThreadItem.Record(id, now),
                )
            }
            is DealCommand.ConfirmRefund -> {
                val record = checkNotNull(deal.records.find { it.id == command.recordId }) { "No such record" }
                check(record.status == RecordStatus.REFUNDED) { "Nothing was refunded" }
                deal.copy(
                    records = deal.records.map { if (it.id == record.id) it.copy(refundConfirmed = true) else it },
                    thread = deal.thread + ThreadItem.Event("check_circle", "Bạn đã nhận ${record.refund!!.full()} tiền hoàn", now),
                )
            }
        }
    }
}
```

- [ ] **Step 5: Write the fake repositories**

`FakeHomeRepository.kt`:

```kotlin
package vn.shopnexus.core.data.fake

import javax.inject.Inject
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import vn.shopnexus.core.data.HomeRepository
import vn.shopnexus.core.model.HomeFeed
import vn.shopnexus.core.model.ListingId
import vn.shopnexus.core.model.ListingSummary

internal fun List<ListingSummary>.withSaved(saved: Set<ListingId>) = map { it.copy(saved = it.id in saved) }

class FakeHomeRepository @Inject constructor(
    private val world: FakeWorld,
    private val failures: FailurePolicy,
) : HomeRepository {
    override fun feed(): Flow<HomeFeed> = flow {
        failures.run {}.getOrThrow()
        emitAll(
            world.flow
                .map { s -> s.home.copy(nearby = s.home.nearby.withSaved(s.saved), forYou = s.home.forYou.withSaved(s.saved)) }
                .distinctUntilChanged(),
        )
    }

    override suspend fun refresh(): Result<Int> = failures.run {
        val arrived = world.value.fresh.size
        world.update { it.copy(home = it.home.copy(nearby = it.fresh + it.home.nearby), fresh = emptyList()) }
        arrived
    }
}
```

`FakeListingRepository.kt`:

```kotlin
package vn.shopnexus.core.data.fake

import javax.inject.Inject
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import vn.shopnexus.core.data.ListingRepository
import vn.shopnexus.core.model.DealRef
import vn.shopnexus.core.model.ListingDetail
import vn.shopnexus.core.model.ListingId
import vn.shopnexus.core.model.ReportReason

class FakeListingRepository @Inject constructor(
    private val world: FakeWorld,
    private val failures: FailurePolicy,
) : ListingRepository {
    override fun detail(id: ListingId): Flow<ListingDetail?> = flow {
        failures.run {}.getOrThrow()
        emitAll(
            world.flow
                .map { s ->
                    s.details[id]?.let { d ->
                        val deal = d.deal?.let { ref ->
                            s.chats[ref.id]?.deal?.let { DealRef(it.id, it.openCounter?.amount, it.openOffer?.amount) } ?: ref
                        }
                        d.copy(saved = id in s.saved, similar = d.similar.withSaved(s.saved), deal = deal)
                    }
                }
                .distinctUntilChanged(),
        )
    }

    override suspend fun setSaved(id: ListingId, saved: Boolean): Result<Unit> = failures.run {
        world.update { it.copy(saved = if (saved) it.saved + id else it.saved - id) }
    }

    /** Stage 1 only checks the call goes through; moderation arrives with the backend. */
    override suspend fun report(id: ListingId, reason: ReportReason): Result<Unit> = failures.run {
        check(id in world.value.details) { "No listing $id" }
    }
}
```

`FakeDealRepository.kt`:

```kotlin
package vn.shopnexus.core.data.fake

import java.time.Clock
import javax.inject.Inject
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import vn.shopnexus.core.data.DealRepository
import vn.shopnexus.core.model.ChatView
import vn.shopnexus.core.model.Deal
import vn.shopnexus.core.model.DealCommand
import vn.shopnexus.core.model.DealId

class FakeDealRepository @Inject constructor(
    private val world: FakeWorld,
    private val failures: FailurePolicy,
    private val engine: FakeDealEngine,
    private val clock: Clock,
    private val counterpart: CounterpartListener,
) : DealRepository {
    override fun chat(id: DealId): Flow<ChatView?> = flow {
        failures.run {}.getOrThrow()
        emitAll(world.flow.map { it.chats[id] }.distinctUntilChanged())
    }

    override fun counterpartTyping(id: DealId): Flow<Boolean> = world.flow.map { id in it.typing }.distinctUntilChanged()

    override suspend fun send(id: DealId, command: DealCommand): Result<Deal> {
        val result = failures.run {
            val view = checkNotNull(world.value.chats[id]) { "No deal $id" }
            val next = engine.apply(view, command, clock.instant())
            world.update { it.copy(chats = it.chats + (id to view.copy(deal = next))) }
            next
        }
        if (result.isSuccess) counterpart.onCommand(id, command)
        return result
    }
}
```

`FakeQrScanner.kt`:

```kotlin
package vn.shopnexus.core.data.fake

import javax.inject.Inject
import kotlinx.coroutines.delay
import vn.shopnexus.core.data.QrScanner

/** Reads Tuấn Kiệt's code after 1.6 s, the time the scanner screen shows its line sweeping. */
class FakeQrScanner @Inject constructor() : QrScanner {
    override suspend fun scan(): Result<String> {
        delay(1_600)
        return Result.success("SNX-KIET")
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./gradlew :core:data:testDebugUnitTest`
Expected: PASS, 15 tests.

- [ ] **Step 7: Commit**

```bash
git add core/data
git commit -m "feat(data): add the fake world, the deal engine and the fake repositories

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: The simulator and dependency injection

The simulator plays Tuấn Kiệt: it answers offers, meeting proposals and records on a schedule, shows typing first, and stops when the buyer withdraws. Hilt binds the fakes to the repository interfaces in `DataModule`.

**Files:**
- Create: `app2/build-logic/convention/src/main/kotlin/HiltConventionPlugin.kt`
- Modify: `app2/build-logic/convention/build.gradle.kts` (register `shopnexus.hilt`)
- Modify: `app2/core/data/build.gradle.kts` (apply `shopnexus.hilt`)
- Create: `app2/core/data/src/main/kotlin/vn/shopnexus/core/data/fake/Simulator.kt`
- Create: `app2/core/data/src/main/kotlin/vn/shopnexus/core/data/di/DataModule.kt`
- Test: `app2/core/data/src/test/kotlin/vn/shopnexus/core/data/fake/SimulatorTest.kt`

**Interfaces:**
- Consumes: `FakeWorld`, `CounterpartListener`, `todayAt`, `meetingLabel` (Tasks 10–11).
- Produces:
  ```kotlin
  @Qualifier annotation class AppScope
  class Simulator(world: FakeWorld, clock: Clock, @AppScope scope: CoroutineScope, zone: ZoneId) : CounterpartListener {
      var speed: Double   // 1.0 = mockup timing; the debug panel sets 4.0
  }
  // Hilt bindings: HomeRepository, ListingRepository, DealRepository, QrScanner, CounterpartListener (= Simulator),
  // Clock (= fixtureClock()), ZoneId (= clock.zone), @AppScope CoroutineScope
  ```

- [ ] **Step 1: Add the Hilt convention plugin**

`app2/build-logic/convention/src/main/kotlin/HiltConventionPlugin.kt`:

```kotlin
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.dependencies

/** Hilt with KSP for Android modules. */
class HiltConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("com.google.devtools.ksp")
        pluginManager.apply("com.google.dagger.hilt.android")
        dependencies {
            add("implementation", libs.library("hilt-android"))
            add("ksp", libs.library("hilt-compiler"))
        }
    }
}
```

Register it in `build-logic/convention/build.gradle.kts`:

```kotlin
        register("hilt") {
            id = "shopnexus.hilt"
            implementationClass = "HiltConventionPlugin"
        }
```

`app2/core/data/build.gradle.kts` plugins block becomes:

```kotlin
plugins {
    id("shopnexus.android.library")
    id("shopnexus.hilt")
}
```

- [ ] **Step 2: Write the failing simulator test**

`SimulatorTest.kt`:

```kotlin
package vn.shopnexus.core.data.fake

import com.google.common.truth.Truth.assertThat
import java.time.Instant
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Test
import vn.shopnexus.core.domain.VN_ZONE
import vn.shopnexus.core.model.DealCommand
import vn.shopnexus.core.model.DealId
import vn.shopnexus.core.model.DealStage
import vn.shopnexus.core.model.MeetPoint
import vn.shopnexus.core.model.MilestoneKind
import vn.shopnexus.core.model.RecordStatus
import vn.shopnexus.core.model.ThreadItem
import vn.shopnexus.core.model.Vnd
import vn.shopnexus.core.testing.SchedulerClock

class SimulatorTest {
    private val id = DealId("d-kiet")

    private fun TestScope.setup(): Pair<FakeWorld, FakeDealRepository> {
        val world = FakeWorld()
        val clock = SchedulerClock(testScheduler)
        val simulator = Simulator(world, clock, backgroundScope, VN_ZONE)
        return world to FakeDealRepository(world, FailurePolicy(latencyMillis = 0), FakeDealEngine(VN_ZONE), clock, simulator)
    }

    @Test
    fun theSellerAcceptsAnOfferAfterTwoPointFourSeconds() = runTest {
        val (world, deals) = setup()
        deals.send(id, DealCommand.SendOffer(Vnd(10_500_000), null))
        advanceTimeBy(900); runCurrent()
        assertThat(id in world.value.typing).isTrue()
        advanceTimeBy(1_500); runCurrent()
        val deal = world.value.chats.getValue(id).deal
        assertThat(id in world.value.typing).isFalse()
        assertThat(deal.stage).isEqualTo(DealStage.ARRANGE)
        assertThat(deal.agreedPrice).isEqualTo(Vnd(10_500_000))
        assertThat(deal.meeting?.place?.name).isEqualTo("Sảnh Landmark 81")
        assertThat(deal.meeting?.at).isEqualTo(Instant.parse("2026-10-15T12:00:00Z"))
        assertThat(deal.thread.last()).isInstanceOf(ThreadItem.Milestone::class.java)
        assertThat((deal.thread.last() as ThreadItem.Milestone).kind).isEqualTo(MilestoneKind.AGREED)
    }

    @Test
    fun withdrawingStopsTheSellerFromAccepting() = runTest {
        val (world, deals) = setup()
        deals.send(id, DealCommand.SendOffer(Vnd(10_500_000), null))
        advanceTimeBy(1_000); runCurrent()
        deals.send(id, DealCommand.WithdrawOffer)
        advanceTimeBy(5_000); runCurrent()
        assertThat(world.value.chats.getValue(id).deal.stage).isEqualTo(DealStage.NEGOTIATE)
        assertThat(id in world.value.typing).isFalse()
    }

    @Test
    fun acceptingTheCounterBringsTheSellersMeetingProposal() = runTest {
        val (world, deals) = setup()
        deals.send(id, DealCommand.AcceptCounter)
        advanceTimeBy(1_600); runCurrent()
        val deal = world.value.chats.getValue(id).deal
        assertThat(deal.meeting?.confirmed).isFalse()
        assertThat((deal.thread.last() as ThreadItem.Text).text).isEqualTo("Ok bạn. Tối nay 19h mình gặp ở sảnh Landmark 81 nhé?")
    }

    @Test
    fun aNewMeetingIsConfirmedAfterOnePointSixSeconds() = runTest {
        val (world, deals) = setup()
        deals.send(id, DealCommand.AcceptCounter)
        advanceTimeBy(2_000); runCurrent()
        deals.send(id, DealCommand.ProposeMeeting(Instant.parse("2026-10-15T13:00:00Z"), MeetPoint("Highlands Phan Xích Long", "Quán đông, có camera")))
        advanceTimeBy(1_700); runCurrent()
        val deal = world.value.chats.getValue(id).deal
        assertThat(deal.stage).isEqualTo(DealStage.HANDOVER)
        assertThat((deal.thread.last() as ThreadItem.Event).text).isEqualTo("Đã hẹn 20:00 hôm nay · Highlands Phan Xích Long")
    }

    @Test
    fun aRecordIsRefundedAfterTwoPointTwoSeconds() = runTest {
        val (world, deals) = setup()
        world.update { s -> s.copy(chats = s.chats.mapValues { (_, v) -> v.copy(deal = v.deal.copy(stage = DealStage.DONE)) }) }
        deals.send(id, DealCommand.OpenRecord("https://x/crack.jpg", "Mặt lưng có vết nứt nhỏ"))
        advanceTimeBy(2_300); runCurrent()
        val record = world.value.chats.getValue(id).deal.records.single()
        assertThat(record.status).isEqualTo(RecordStatus.REFUNDED)
        assertThat(record.refund).isEqualTo(Vnd(300_000))
    }

    @Test
    fun speedShortensEveryWait() = runTest {
        val world = FakeWorld()
        val clock = SchedulerClock(testScheduler)
        val simulator = Simulator(world, clock, backgroundScope, VN_ZONE).apply { speed = 4.0 }
        val deals = FakeDealRepository(world, FailurePolicy(latencyMillis = 0), FakeDealEngine(VN_ZONE), clock, simulator)
        deals.send(id, DealCommand.SendOffer(Vnd(10_500_000), null))
        advanceTimeBy(700); runCurrent()
        assertThat(world.value.chats.getValue(id).deal.stage).isEqualTo(DealStage.ARRANGE)
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `./gradlew :core:data:testDebugUnitTest --tests "*SimulatorTest*"`
Expected: FAIL, `Unresolved reference 'Simulator'`.

- [ ] **Step 4: Write the simulator**

`Simulator.kt`:

```kotlin
package vn.shopnexus.core.data.fake

import java.time.Clock
import java.time.Instant
import java.time.ZoneId
import javax.inject.Inject
import javax.inject.Qualifier
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import vn.shopnexus.core.domain.meetingLabel
import vn.shopnexus.core.domain.todayAt
import vn.shopnexus.core.model.ChatView
import vn.shopnexus.core.model.DealCommand
import vn.shopnexus.core.model.DealId
import vn.shopnexus.core.model.DealStage
import vn.shopnexus.core.model.Meeting
import vn.shopnexus.core.model.MilestoneKind
import vn.shopnexus.core.model.OfferStatus
import vn.shopnexus.core.model.Party
import vn.shopnexus.core.model.RecordStatus
import vn.shopnexus.core.model.ThreadItem
import vn.shopnexus.core.model.Vnd
import vn.shopnexus.core.model.full
import vn.shopnexus.core.model.short

@Qualifier
@Retention(AnnotationRetention.BINARY)
annotation class AppScope

/** Plays the seller. Timings follow the mockups; [speed] divides them all. */
@Singleton
class Simulator @Inject constructor(
    private val world: FakeWorld,
    private val clock: Clock,
    @AppScope private val scope: CoroutineScope,
    private val zone: ZoneId,
) : CounterpartListener {
    var speed: Double = 1.0
    private val jobs = mutableMapOf<DealId, Job>()

    override fun onCommand(id: DealId, command: DealCommand) {
        when (command) {
            is DealCommand.SendOffer -> after(id, 2_400) { view, now -> acceptOffer(view, command.amount, now) }
            DealCommand.AcceptCounter -> after(id, 1_500) { view, now -> proposeMeeting(view, now) }
            DealCommand.WithdrawOffer -> cancel(id)
            is DealCommand.ProposeMeeting -> after(id, 1_600) { view, now -> confirmMeeting(view, now) }
            is DealCommand.OpenRecord -> after(id, 2_200) { view, now -> refund(view, Vnd(300_000), now) }
            else -> Unit
        }
    }

    private fun after(id: DealId, millis: Long, reply: (ChatView, Instant) -> ChatView) {
        jobs.remove(id)?.cancel()
        jobs[id] = scope.launch {
            val total = (millis / speed).toLong()
            delay(total / 3)
            setTyping(id, true)
            delay(total - total / 3)
            setTyping(id, false)
            world.update { s -> s.chats[id]?.let { s.copy(chats = s.chats + (id to reply(it, clock.instant()))) } ?: s }
            jobs.remove(id)
        }
    }

    private fun cancel(id: DealId) {
        jobs.remove(id)?.cancel()
        setTyping(id, false)
    }

    private fun setTyping(id: DealId, on: Boolean) =
        world.update { it.copy(typing = if (on) it.typing + id else it.typing - id) }

    private fun sellerProposal(view: ChatView, now: Instant) =
        Meeting(todayAt(19, 0, now, zone), view.deal.meetPoints.first(), Party.SELLER, confirmed = false)

    private fun say(text: String, now: Instant) = ThreadItem.Text(Party.SELLER, text, now)

    private fun acceptOffer(view: ChatView, amount: Vnd, now: Instant): ChatView {
        val deal = view.deal
        if (deal.openOffer?.amount != amount) return view
        return view.copy(deal = deal.copy(
            stage = DealStage.ARRANGE,
            agreedPrice = amount,
            meeting = sellerProposal(view, now),
            offers = deal.offers.map {
                when {
                    it.by == Party.BUYER && it.status == OfferStatus.OPEN -> it.copy(status = OfferStatus.ACCEPTED)
                    it.status == OfferStatus.OPEN -> it.copy(status = OfferStatus.SUPERSEDED)
                    else -> it
                }
            },
            thread = deal.thread +
                say("Ok bạn, ${amount.short()} mình chốt luôn. Tối nay 19h gặp ở sảnh Landmark 81 nhé?", now) +
                ThreadItem.PriceMove(Party.SELLER, amount, accepted = true, at = now) +
                ThreadItem.Milestone(MilestoneKind.AGREED, now),
        ))
    }

    private fun proposeMeeting(view: ChatView, now: Instant): ChatView {
        val deal = view.deal
        if (deal.stage != DealStage.ARRANGE || deal.meeting != null) return view
        return view.copy(deal = deal.copy(
            meeting = sellerProposal(view, now),
            thread = deal.thread + say("Ok bạn. Tối nay 19h mình gặp ở sảnh Landmark 81 nhé?", now),
        ))
    }

    private fun confirmMeeting(view: ChatView, now: Instant): ChatView {
        val deal = view.deal
        val meeting = deal.meeting ?: return view
        if (deal.stage != DealStage.ARRANGE) return view
        val confirmed = meeting.copy(confirmed = true)
        return view.copy(deal = deal.copy(
            stage = DealStage.HANDOVER,
            meeting = confirmed,
            thread = deal.thread + say("Ok bạn, hẹn vậy nhé.", now) +
                ThreadItem.Event("event_available", "Đã hẹn ${meetingLabel(confirmed.at, now, zone)} · ${confirmed.place.name}", now),
        ))
    }

    private fun refund(view: ChatView, amount: Vnd, now: Instant): ChatView {
        val deal = view.deal
        val open = deal.records.lastOrNull { it.status == RecordStatus.OPEN } ?: return view
        return view.copy(deal = deal.copy(
            records = deal.records.map { if (it.id == open.id) it.copy(status = RecordStatus.REFUNDED, refund = amount) else it },
            thread = deal.thread + say("Mình xin lỗi, mình không để ý vết đó. Mình hoàn bạn ${amount.full()} nhé.", now),
        ))
    }
}
```

- [ ] **Step 5: Write the Hilt module**

`app2/core/data/src/main/kotlin/vn/shopnexus/core/data/di/DataModule.kt`:

```kotlin
package vn.shopnexus.core.data.di

import dagger.Binds
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import java.time.Clock
import java.time.ZoneId
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import vn.shopnexus.core.data.DealRepository
import vn.shopnexus.core.data.HomeRepository
import vn.shopnexus.core.data.ListingRepository
import vn.shopnexus.core.data.QrScanner
import vn.shopnexus.core.data.fake.AppScope
import vn.shopnexus.core.data.fake.CounterpartListener
import vn.shopnexus.core.data.fake.FailurePolicy
import vn.shopnexus.core.data.fake.FakeDealRepository
import vn.shopnexus.core.data.fake.FakeHomeRepository
import vn.shopnexus.core.data.fake.FakeListingRepository
import vn.shopnexus.core.data.fake.FakeQrScanner
import vn.shopnexus.core.data.fake.Simulator
import vn.shopnexus.core.data.fake.fixtureClock

/** Stage 1 runs on fakes only; a later stage swaps these bindings for network ones. */
@Module
@InstallIn(SingletonComponent::class)
abstract class DataModule {
    @Binds abstract fun home(impl: FakeHomeRepository): HomeRepository
    @Binds abstract fun listings(impl: FakeListingRepository): ListingRepository
    @Binds abstract fun deals(impl: FakeDealRepository): DealRepository
    @Binds abstract fun scanner(impl: FakeQrScanner): QrScanner
    @Binds abstract fun counterpart(impl: Simulator): CounterpartListener

    companion object {
        @Provides @Singleton fun clock(): Clock = fixtureClock()
        @Provides @Singleton fun failures(): FailurePolicy = FailurePolicy()
        @Provides fun zone(clock: Clock): ZoneId = clock.zone
        @Provides @Singleton @AppScope
        fun scope(): CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./gradlew :core:data:testDebugUnitTest`
Expected: PASS, 21 tests. KSP runs Hilt's processor on the module without errors.

- [ ] **Step 7: Commit**

```bash
git add build-logic core/data
git commit -m "feat(data): add the seller simulator and the Hilt bindings for the fakes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```


---

### Task 13: Theme and screenshot harness (`:core:designsystem`)

The theme that every screen wraps in, the Be Vietnam Pro font, the Material Symbols the slice uses, and a screenshot harness that renders anything in the four variants the spec asks for.

**Files:**
- Create: `app2/build-logic/convention/src/main/kotlin/AndroidLibraryComposeConventionPlugin.kt`
- Modify: `app2/build-logic/convention/build.gradle.kts` (register `shopnexus.android.library.compose`)
- Modify: `app2/settings.gradle.kts` (add `include(":core:designsystem")`)
- Modify: `app2/core/testing/build.gradle.kts` (switch to the Compose plugin, add the harness dependencies)
- Create: `app2/core/designsystem/build.gradle.kts`
- Create: `app2/core/designsystem/src/main/res/font/be_vietnam_pro_regular.ttf`, `be_vietnam_pro_medium.ttf`, `be_vietnam_pro_semibold.ttf`, `app2/core/designsystem/src/main/res/font/OFL.txt`
- Create in `app2/core/designsystem/src/main/kotlin/vn/shopnexus/core/designsystem/theme/`: `Color.kt`, `Type.kt`, `Shape.kt`, `Theme.kt`
- Create: `app2/core/designsystem/symbols.txt`, `app2/core/designsystem/tools/gen_symbols.py`
- Create (generated): `app2/core/designsystem/src/main/kotlin/vn/shopnexus/core/designsystem/icon/Symbols.kt`
- Create: `app2/core/designsystem/src/main/kotlin/vn/shopnexus/core/designsystem/icon/SymbolIcon.kt`
- Create: `app2/core/designsystem/src/main/kotlin/vn/shopnexus/core/designsystem/component/Loading.kt`
- Create: `app2/core/testing/src/main/kotlin/vn/shopnexus/core/testing/Screenshots.kt`
- Create: `app2/core/testing/src/main/resources/robolectric.properties`, `app2/core/designsystem/src/test/resources/robolectric.properties`
- Test: `app2/core/designsystem/src/test/kotlin/vn/shopnexus/core/designsystem/ThemeScreenshotTest.kt`
- Test: `app2/core/designsystem/src/test/kotlin/vn/shopnexus/core/designsystem/SymbolsTest.kt`

**Interfaces:**
- Consumes: `Vnd`, `full()`, `short()`, `cardParts()` (Task 10).
- Produces:
  ```kotlin
  enum class ThemeMode { SYSTEM, LIGHT, DARK }
  @Composable fun ShopNexusTheme(themeMode: ThemeMode = ThemeMode.SYSTEM, dynamicColor: Boolean = false,
                                 sampleDynamic: Boolean = false, content: @Composable () -> Unit)
  @Immutable data class ExtendedColors(val tertiaryFixed: Color, val onTertiaryFixedVariant: Color)
  object ShopNexusTheme { val extended: ExtendedColors @Composable get }
  object Corners { val ExtraSmall; val Small; val Medium; val Large; val LargeIncreased; val ExtraLarge; val ExtraLargeIncreased: RoundedCornerShape }
  val BeVietnamPro: FontFamily
  enum class Symbol(val id: String) { …; companion object { fun of(id: String): Symbol? } }
  fun Symbol.vector(filled: Boolean = false): ImageVector
  @Composable fun SymbolIcon(symbol: Symbol, contentDescription: String?, modifier: Modifier = Modifier,
                             filled: Boolean = false, size: Dp = 24.dp, tint: Color = LocalContentColor.current)
  @Composable fun ShopNexusLoading(modifier: Modifier = Modifier, contained: Boolean = true)   // 48 dp
  // :core:testing
  enum class Variant { LIGHT, DARK, DYNAMIC, FONT_130 }
  fun ComposeContentTestRule.captureVariants(name: String, content: @Composable () -> Unit)
  fun ComposeContentTestRule.captureScreen(name: String, variant: Variant = Variant.LIGHT, content: @Composable () -> Unit)
  fun fakeImages()   // every photo becomes one flat grey; UI tests call it before setContent
  annotation class ScreenshotConfig   // documents the @Config every screenshot test uses
  ```

- [ ] **Step 1: Add the Compose library convention plugin**

`app2/build-logic/convention/src/main/kotlin/AndroidLibraryComposeConventionPlugin.kt`:

```kotlin
import com.android.build.api.dsl.LibraryExtension
import org.gradle.api.JavaVersion
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.dependencies

/** Android libraries with Compose, Robolectric and Roborazzi screenshot tests. */
class AndroidLibraryComposeConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("com.android.library")
        pluginManager.apply("org.jetbrains.kotlin.plugin.compose")
        pluginManager.apply("org.jetbrains.kotlin.plugin.serialization")
        pluginManager.apply("io.github.takahirom.roborazzi")
        extensions.configure<LibraryExtension> {
            compileSdk = 36
            defaultConfig { minSdk = 31 }
            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_21
                targetCompatibility = JavaVersion.VERSION_21
            }
            buildFeatures { compose = true }
            testOptions { unitTests { isIncludeAndroidResources = true } }
        }
        dependencies {
            val bom = libs.library("androidx-compose-bom")
            add("implementation", platform(bom))
            add("testImplementation", platform(bom))
            add("implementation", libs.library("androidx-compose-ui"))
            add("implementation", libs.library("androidx-compose-foundation"))
            add("implementation", libs.library("androidx-compose-material3"))
            add("implementation", libs.library("androidx-compose-ui-tooling-preview"))
            add("debugImplementation", libs.library("androidx-compose-ui-tooling"))
            add("debugImplementation", libs.library("androidx-compose-ui-test-manifest"))
            add("implementation", libs.library("kotlinx-coroutines-core"))
            add("implementation", libs.library("kotlinx-serialization-json"))
            add("testImplementation", libs.library("junit"))
            add("testImplementation", libs.library("truth"))
            add("testImplementation", libs.library("robolectric"))
            add("testImplementation", libs.library("androidx-test-ext-junit"))
            add("testImplementation", libs.library("androidx-compose-ui-test-junit4"))
            add("testImplementation", libs.library("roborazzi"))
            add("testImplementation", libs.library("roborazzi-compose"))
        }
    }
}
```

Register it in `build-logic/convention/build.gradle.kts`:

```kotlin
        register("androidLibraryCompose") {
            id = "shopnexus.android.library.compose"
            implementationClass = "AndroidLibraryComposeConventionPlugin"
        }
```

- [ ] **Step 2: Create the module and switch `:core:testing` to Compose**

Add `include(":core:designsystem")` to `app2/settings.gradle.kts`.

`app2/core/designsystem/build.gradle.kts`:

```kotlin
plugins {
    id("shopnexus.android.library.compose")
}

android {
    namespace = "vn.shopnexus.core.designsystem"
}

dependencies {
    api(project(":core:model"))
    api(libs.coil.compose)
    implementation(libs.coil.network.okhttp)
    implementation(libs.androidx.core.ktx)
    testImplementation(project(":core:testing"))
}
```

`app2/core/testing/build.gradle.kts` becomes:

```kotlin
plugins {
    id("shopnexus.android.library.compose")
}

android {
    namespace = "vn.shopnexus.core.testing"
}

dependencies {
    api(project(":core:data"))
    api(project(":core:designsystem"))
    api(libs.junit)
    api(libs.kotlinx.coroutines.test)
    api(libs.turbine)
    api(libs.truth)
    api(libs.robolectric)
    api(libs.androidx.test.core)
    api(libs.androidx.test.ext.junit)
    api(libs.coil.test)
    api(platform(libs.androidx.compose.bom))
    api(libs.androidx.compose.ui.test.junit4)
    api(libs.roborazzi)
    api(libs.roborazzi.compose)
}
```

`:core:designsystem` tests use `:core:testing`, which uses `:core:designsystem`. Gradle accepts this: the test source set of one module depends on the main source set of the other, so no task waits on itself.

- [ ] **Step 3: Download the fonts**

```bash
cd /home/beanbocchi/shopnexus/app2/core/designsystem/src/main/res
mkdir -p font
for w in Regular Medium SemiBold; do
  lower=$(echo "$w" | tr '[:upper:]' '[:lower:]')
  curl -fsSL "https://github.com/google/fonts/raw/main/ofl/bevietnampro/BeVietnamPro-$w.ttf" -o "font/be_vietnam_pro_$lower.ttf"
done
curl -fsSL https://github.com/google/fonts/raw/main/ofl/bevietnampro/OFL.txt -o font/OFL.txt
file font/*.ttf
```
Expected: three lines ending in `TrueType Font data`. Android resource names allow only lowercase letters, digits and `_`, so `OFL.txt` cannot stay in `res/font`: move it with `mv font/OFL.txt ../../../OFL-BeVietnamPro.txt` (it lands at `core/designsystem/OFL-BeVietnamPro.txt`), and fix the path in the file list above when you commit.

- [ ] **Step 4: Write the colours, type and shapes**

`theme/Color.kt`, the values from `LIGHT`, `DARK` and `DYNAMIC_LIGHT`/`DYNAMIC_DARK` in `.superdesign/tools/common.py`:

```kotlin
package vn.shopnexus.core.designsystem.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

internal val LightScheme: ColorScheme = lightColorScheme(
    primary = Color(0xFF005049), onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFF066A61), onPrimaryContainer = Color(0xFF97E7DB),
    secondary = Color(0xFF47645F), onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFC7E6E0), onSecondaryContainer = Color(0xFF4B6863),
    tertiary = Color(0xFF773115), onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFF95482A), onTertiaryContainer = Color(0xFFFFCDBC),
    error = Color(0xFFBA1A1A), onError = Color(0xFFFFFFFF),
    errorContainer = Color(0xFFFFDAD6), onErrorContainer = Color(0xFF93000A),
    background = Color(0xFFF7FAF8), onBackground = Color(0xFF181C1C),
    surface = Color(0xFFF7FAF8), onSurface = Color(0xFF181C1C),
    surfaceVariant = Color(0xFFE0E3E1), onSurfaceVariant = Color(0xFF3E4947),
    surfaceContainerLowest = Color(0xFFFFFFFF), surfaceContainerLow = Color(0xFFF1F4F2),
    surfaceContainer = Color(0xFFEBEFED), surfaceContainerHigh = Color(0xFFE6E9E7),
    surfaceContainerHighest = Color(0xFFE0E3E1),
    inverseSurface = Color(0xFF2D3130), inverseOnSurface = Color(0xFFEEF1EF), inversePrimary = Color(0xFF85D5C9),
    outline = Color(0xFF6E7977), outlineVariant = Color(0xFFBEC9C6),
)

internal val DarkScheme: ColorScheme = darkColorScheme(
    primary = Color(0xFF85D5C9), onPrimary = Color(0xFF003732),
    primaryContainer = Color(0xFF066A61), onPrimaryContainer = Color(0xFF97E7DB),
    secondary = Color(0xFFAECDC7), onSecondary = Color(0xFF193531),
    secondaryContainer = Color(0xFF324E4A), onSecondaryContainer = Color(0xFFA0BFB9),
    tertiary = Color(0xFFFFB59A), onTertiary = Color(0xFF5A1C02),
    tertiaryContainer = Color(0xFF95482A), onTertiaryContainer = Color(0xFFFFCDBC),
    error = Color(0xFFFFB4AB), onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A), onErrorContainer = Color(0xFFFFDAD6),
    background = Color(0xFF101413), onBackground = Color(0xFFE0E3E1),
    surface = Color(0xFF101413), onSurface = Color(0xFFE0E3E1),
    surfaceVariant = Color(0xFF313635), onSurfaceVariant = Color(0xFFBEC9C6),
    surfaceContainerLowest = Color(0xFF0B0F0E), surfaceContainerLow = Color(0xFF181C1C),
    surfaceContainer = Color(0xFF1C2020), surfaceContainerHigh = Color(0xFF272B2A),
    surfaceContainerHighest = Color(0xFF313635),
    inverseSurface = Color(0xFFE0E3E1), inverseOnSurface = Color(0xFF2D3130), inversePrimary = Color(0xFF066A61),
    outline = Color(0xFF889390), outlineVariant = Color(0xFF3E4947),
)

/** Material You from the sample wallpaper; screenshots and previews use it where a device would use its own. */
internal val SampleDynamicLight: ColorScheme = lightColorScheme(
    primary = Color(0xFF8C4F3D), onPrimary = Color(0xFFFFF7F5),
    primaryContainer = Color(0xFFFAAB95), onPrimaryContainer = Color(0xFF5F2B1C),
    secondary = Color(0xFF78574E), onSecondary = Color(0xFFFFF7F5),
    secondaryContainer = Color(0xFFFFDBD1), onSecondaryContainer = Color(0xFF694A42),
    tertiary = Color(0xFF765B25), onTertiary = Color(0xFFFFF8F1),
    tertiaryContainer = Color(0xFFFDD896), onTertiaryContainer = Color(0xFF634A16),
    error = Color(0xFFA83836), onError = Color(0xFFFFF7F6),
    background = Color(0xFFFFF8F6), onBackground = Color(0xFF3E2F2B),
    surface = Color(0xFFFFF8F6), onSurface = Color(0xFF3E2F2B),
    surfaceVariant = Color(0xFFF6DDD7), onSurfaceVariant = Color(0xFF6D5B56),
    surfaceContainerLowest = Color(0xFFFFFFFF), surfaceContainerLow = Color(0xFFFFF1ED),
    surfaceContainer = Color(0xFFFFE9E4), surfaceContainerHigh = Color(0xFFFAE3DE),
    surfaceContainerHighest = Color(0xFFF6DDD7),
    inverseSurface = Color(0xFF130D0B), inverseOnSurface = Color(0xFFA79A97), inversePrimary = Color(0xFFFAAB95),
    outline = Color(0xFF8A7671), outlineVariant = Color(0xFFC3ADA7),
)

internal val SampleDynamicDark: ColorScheme = darkColorScheme(
    primary = Color(0xFFF9B7A5), onPrimary = Color(0xFF613427),
    primaryContainer = Color(0xFF764638), onPrimaryContainer = Color(0xFFFFDCD2),
    secondary = Color(0xFFE7BDB2), onSecondary = Color(0xFF563931),
    secondaryContainer = Color(0xFF51352D), onSecondaryContainer = Color(0xFFDFB6AB),
    tertiary = Color(0xFFFFE8C4), onTertiary = Color(0xFF6D531E),
    tertiaryContainer = Color(0xFFFDD896), onTertiaryContainer = Color(0xFF634A16),
    error = Color(0xFFFA746F), onError = Color(0xFF490006),
    background = Color(0xFF130D0B), onBackground = Color(0xFFF9E0DA),
    surface = Color(0xFF130D0B), onSurface = Color(0xFFF9E0DA),
    surfaceVariant = Color(0xFF30231F), onSurfaceVariant = Color(0xFFBCA6A1),
    surfaceContainerLowest = Color(0xFF000000), surfaceContainerLow = Color(0xFF1A110F),
    surfaceContainer = Color(0xFF221714), surfaceContainerHigh = Color(0xFF291D1A),
    surfaceContainerHighest = Color(0xFF30231F),
    inverseSurface = Color(0xFFFFF8F6), inverseOnSurface = Color(0xFF5D5350), inversePrimary = Color(0xFF855244),
    outline = Color(0xFF84716C), outlineVariant = Color(0xFF554440),
)

/** The tonal terracotta, the same in light and dark: a sent offer, a picked amount, the agreed-price milestone. */
@Immutable
data class ExtendedColors(val tertiaryFixed: Color, val onTertiaryFixedVariant: Color)

internal val BrandExtended = ExtendedColors(tertiaryFixed = Color(0xFFFFDBCF), onTertiaryFixedVariant = Color(0xFF773215))
internal val SampleDynamicExtended = ExtendedColors(tertiaryFixed = Color(0xFFFDD896), onTertiaryFixedVariant = Color(0xFF6E541F))

internal val LocalExtendedColors = staticCompositionLocalOf { BrandExtended }
```

`theme/Type.kt`:

```kotlin
package vn.shopnexus.core.designsystem.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import vn.shopnexus.core.designsystem.R

/** Drawn for Vietnamese diacritics; bundled, so the first launch needs no network. */
val BeVietnamPro = FontFamily(
    Font(R.font.be_vietnam_pro_regular, FontWeight.Normal),
    Font(R.font.be_vietnam_pro_medium, FontWeight.Medium),
    Font(R.font.be_vietnam_pro_semibold, FontWeight.SemiBold),
)

private fun style(size: Int, line: Int, weight: FontWeight, tracking: Double) = TextStyle(
    fontFamily = BeVietnamPro,
    fontWeight = weight,
    fontSize = size.sp,
    lineHeight = line.sp,
    letterSpacing = tracking.sp,
)

/** The mockup scale (`TYPE` in common.py). No style goes tighter than its line height: Vietnamese stacks accents. */
internal val ShopNexusTypography = Typography(
    displaySmall = style(36, 44, FontWeight.Normal, 0.0),
    headlineMedium = style(28, 36, FontWeight.Normal, 0.0),
    headlineSmall = style(24, 32, FontWeight.Normal, 0.0),
    titleLarge = style(22, 28, FontWeight.Normal, 0.0),
    titleMedium = style(16, 24, FontWeight.Medium, 0.15),
    titleSmall = style(14, 20, FontWeight.Medium, 0.1),
    bodyLarge = style(16, 24, FontWeight.Normal, 0.5),
    bodyMedium = style(14, 20, FontWeight.Normal, 0.25),
    bodySmall = style(12, 16, FontWeight.Normal, 0.4),
    labelLarge = style(14, 20, FontWeight.Medium, 0.1),
    labelMedium = style(12, 16, FontWeight.Medium, 0.5),
    labelSmall = style(11, 16, FontWeight.Medium, 0.5),
)
```

`theme/Shape.kt`:

```kotlin
package vn.shopnexus.core.designsystem.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Shapes
import androidx.compose.ui.unit.dp

/** The M3 Expressive corner scale; components take their shape from here. */
object Corners {
    val ExtraSmall = RoundedCornerShape(4.dp)
    val Small = RoundedCornerShape(8.dp)
    val Medium = RoundedCornerShape(12.dp)
    val Large = RoundedCornerShape(16.dp)
    val LargeIncreased = RoundedCornerShape(20.dp)
    val ExtraLarge = RoundedCornerShape(28.dp)
    val ExtraLargeIncreased = RoundedCornerShape(32.dp)
}

internal val ShopNexusShapes = Shapes(
    extraSmall = Corners.ExtraSmall,
    small = Corners.Small,
    medium = Corners.Medium,
    large = Corners.Large,
    extraLarge = Corners.ExtraLarge,
)
```

`theme/Theme.kt`:

```kotlin
package vn.shopnexus.core.designsystem.theme

import android.content.Context
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.MotionScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

enum class ThemeMode { SYSTEM, LIGHT, DARK }

/**
 * Brand colours by default; Material You when [dynamicColor] is on. [sampleDynamic] swaps the
 * device wallpaper for the sample one, so screenshots and previews show Material You the same everywhere.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ShopNexusTheme(
    themeMode: ThemeMode = ThemeMode.SYSTEM,
    dynamicColor: Boolean = false,
    sampleDynamic: Boolean = false,
    content: @Composable () -> Unit,
) {
    val dark = when (themeMode) {
        ThemeMode.SYSTEM -> isSystemInDarkTheme()
        ThemeMode.LIGHT -> false
        ThemeMode.DARK -> true
    }
    val context = LocalContext.current
    val scheme = when {
        dynamicColor && sampleDynamic -> if (dark) SampleDynamicDark else SampleDynamicLight
        dynamicColor -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        else -> if (dark) DarkScheme else LightScheme
    }
    val extended = when {
        dynamicColor && sampleDynamic -> SampleDynamicExtended
        dynamicColor -> context.dynamicExtended()
        else -> BrandExtended
    }
    CompositionLocalProvider(LocalExtendedColors provides extended) {
        MaterialExpressiveTheme(
            colorScheme = scheme,
            motionScheme = MotionScheme.expressive(),
            shapes = ShopNexusShapes,
            typography = ShopNexusTypography,
            content = content,
        )
    }
}

/** The fixed tertiary roles are tones 90 and 30 of the wallpaper's third accent palette. */
private fun Context.dynamicExtended() = ExtendedColors(
    tertiaryFixed = Color(getColor(android.R.color.system_accent3_100)),
    onTertiaryFixedVariant = Color(getColor(android.R.color.system_accent3_700)),
)

object ShopNexusTheme {
    val extended: ExtendedColors
        @Composable @ReadOnlyComposable get() = LocalExtendedColors.current
}
```

- [ ] **Step 5: Write the symbol list and the generator**

`app2/core/designsystem/symbols.txt`, one Material Symbols name per line; `fill` after a name also fetches the filled variant:

```text
account_balance
add
add_a_photo
add_circle
apparel
arrow_back
arrow_forward
auto_awesome fill
balance
battery_full_alt
blender
block
chair
chat fill
check
check_circle fill
checklist
chevron_right
close
cloud_off
content_copy
draft
edit_calendar
edit_note
error
event
event_available
expand_more
familiar_face_and_zone
favorite fill
flag
gavel
grid_view fill
handshake
home fill
hourglass_top
image_search
info
keyboard_arrow_down
laptop_chromebook
local_shipping
location_on fill
mobile
more_vert
notifications fill
package_2
pause
person fill
phone_android
photo_camera
pin
play_arrow
qr_code_2
qr_code_scanner
refresh
remove
report
schedule
search
sell
send
share
shield
sports_tennis
star fill
storefront
stroller
timer
two_wheeler
undo
verified fill
videocam
visibility_off
wifi_off
workspace_premium
```

`app2/core/designsystem/tools/gen_symbols.py`:

```python
"""Write Symbols.kt from symbols.txt: Material Symbols Rounded, weight 400, 24 px.

Run from app2/core/designsystem: python3 tools/gen_symbols.py
Each icon is downloaded as an SVG and kept as its path data, so the app ships
only the icons it uses instead of the 15 MB variable font.
"""
import pathlib
import re
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "src/main/kotlin/vn/shopnexus/core/designsystem/icon/Symbols.kt"
URL = "https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsrounded/{name}/{style}/24px.svg"


def path_of(name, style):
    with urllib.request.urlopen(URL.format(name=name, style=style), timeout=30) as response:
        svg = response.read().decode()
    paths = re.findall(r'<path d="([^"]+)"', svg)
    if not paths or 'viewBox="0 -960 960 960"' not in svg:
        raise SystemExit(f"Unexpected SVG for {name} ({style})")
    return " ".join(paths)


def enum_name(name):
    return "".join(part.capitalize() for part in name.split("_")).replace("2", "Two")


def main():
    entries, paths = [], []
    for line in (ROOT / "symbols.txt").read_text().splitlines():
        if not line.strip():
            continue
        name, *flags = line.split()
        entries.append(f'    {enum_name(name)}("{name}"),')
        paths.append(f'    "{name}" to "{path_of(name, "default")}",')
        if "fill" in flags:
            paths.append(f'    "{name}.fill" to "{path_of(name, "fill1")}",')
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        "// Generated by tools/gen_symbols.py from symbols.txt. Do not edit.\n"
        "package vn.shopnexus.core.designsystem.icon\n\n"
        "enum class Symbol(val id: String) {\n" + "\n".join(entries) + "\n    ;\n\n"
        "    companion object {\n"
        "        private val byId = entries.associateBy { it.id }\n"
        "        fun of(id: String): Symbol? = byId[id]\n"
        "    }\n}\n\n"
        "internal val SymbolPaths: Map<String, String> = mapOf(\n" + "\n".join(paths) + "\n)\n"
    )
    print(f"{len(entries)} symbols, {len(paths)} paths -> {OUT.relative_to(ROOT)}")


main()
```

Run:

```bash
cd /home/beanbocchi/shopnexus/app2/core/designsystem && python3 tools/gen_symbols.py
```
Expected: `75 symbols, 86 paths -> src/main/kotlin/vn/shopnexus/core/designsystem/icon/Symbols.kt`. The enum names read like `Symbol.AutoAwesome`, `Symbol.QrCodeTwo`, `Symbol.PackageTwo`.

- [ ] **Step 6: Write the icon composable and the loading indicator**

`icon/SymbolIcon.kt`:

```kotlin
package vn.shopnexus.core.designsystem.icon

import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.graphics.vector.group
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.size

private val cache = HashMap<String, ImageVector>()

/** The SVGs use the viewBox 0 -960 960 960, so the paths are shifted down by 960. */
fun Symbol.vector(filled: Boolean = false): ImageVector {
    val key = if (filled && "$id.fill" in SymbolPaths) "$id.fill" else id
    return cache.getOrPut(key) {
        ImageVector.Builder(name = key, defaultWidth = 24.dp, defaultHeight = 24.dp, viewportWidth = 960f, viewportHeight = 960f)
            .apply {
                group(translationY = 960f) {
                    addPath(pathData = addPathNodes(SymbolPaths.getValue(key)), fill = SolidColor(Color.Black))
                }
            }
            .build()
    }
}

@Composable
fun SymbolIcon(
    symbol: Symbol,
    contentDescription: String?,
    modifier: Modifier = Modifier,
    filled: Boolean = false,
    size: Dp = 24.dp,
    tint: Color = LocalContentColor.current,
) {
    Icon(symbol.vector(filled), contentDescription, modifier.size(size), tint)
}
```

`component/Loading.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.foundation.layout.size
import androidx.compose.material3.ContainedLoadingIndicator
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import vn.shopnexus.core.designsystem.R

private val morph = listOf(
    MaterialShapes.SoftBurst, MaterialShapes.Cookie9Sided, MaterialShapes.Flower, MaterialShapes.Sunny, MaterialShapes.Clover4Leaf,
)

/** The M3 Expressive indicator, morphing through the five shapes `loading_indicator()` uses in the mockups. */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ShopNexusLoading(modifier: Modifier = Modifier, contained: Boolean = true) {
    val label = stringResource(R.string.loading)
    val m = modifier.size(48.dp).semantics { contentDescription = label }
    if (contained) {
        ContainedLoadingIndicator(
            modifier = m,
            containerColor = MaterialTheme.colorScheme.primaryContainer,
            indicatorColor = MaterialTheme.colorScheme.onPrimaryContainer,
            polygons = morph,
        )
    } else {
        LoadingIndicator(modifier = m, color = MaterialTheme.colorScheme.primary, polygons = morph)
    }
}
```

Create `app2/core/designsystem/src/main/res/values/strings.xml` with the first string; Tasks 14 to 16 add to it:

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="loading">Đang tải</string>
</resources>
```

- [ ] **Step 7: Write the screenshot harness**

`app2/core/testing/src/main/kotlin/vn/shopnexus/core/testing/Screenshots.kt`:

```kotlin
package vn.shopnexus.core.testing

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.ComposeContentTestRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import coil3.ColorImage
import coil3.ImageLoader
import coil3.SingletonImageLoader
import coil3.annotation.ExperimentalCoilApi
import coil3.test.FakeImageLoaderEngine
import com.github.takahirom.roborazzi.RoborazziOptions
import com.github.takahirom.roborazzi.captureRoboImage
import vn.shopnexus.core.designsystem.theme.ShopNexusTheme
import vn.shopnexus.core.designsystem.theme.ThemeMode

/** The four ways every component and screen is checked. */
enum class Variant(val suffix: String) { LIGHT("light"), DARK("dark"), DYNAMIC("dynamic"), FONT_130("font130") }

/**
 * Every screenshot test class carries
 * `@RunWith(AndroidJUnit4::class) @GraphicsMode(GraphicsMode.Mode.NATIVE) @Config(qualifiers = "w412dp-h915dp-xhdpi")`.
 */
annotation class ScreenshotConfig

private val options = RoborazziOptions(compareOptions = RoborazziOptions.CompareOptions(changeThreshold = 0.01f))

/** In tests every photo is one flat grey, so screenshots and UI tests never depend on the network. */
@OptIn(ExperimentalCoilApi::class)
fun fakeImages() {
    val engine = FakeImageLoaderEngine.Builder().default(ColorImage(0xFFB8C2BF.toInt())).build()
    val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    SingletonImageLoader.setUnsafe(ImageLoader.Builder(context).components { add(engine) }.build())
}

@Composable
fun VariantFrame(variant: Variant, width: Dp = 412.dp, content: @Composable () -> Unit) {
    val density = LocalDensity.current
    val fontScale = if (variant == Variant.FONT_130) 1.3f else 1f
    CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale)) {
        ShopNexusTheme(
            themeMode = if (variant == Variant.DARK) ThemeMode.DARK else ThemeMode.LIGHT,
            dynamicColor = variant == Variant.DYNAMIC,
            sampleDynamic = true,
        ) {
            Surface(color = MaterialTheme.colorScheme.surface) {
                Box(Modifier.width(width)) { content() }
            }
        }
    }
}

/** Captures `src/test/screenshots/<name>-<variant>.png` for all four variants. */
fun ComposeContentTestRule.captureVariants(name: String, width: Dp = 412.dp, content: @Composable () -> Unit) {
    fakeImages()
    var variant by mutableStateOf(Variant.LIGHT)
    setContent { key(variant) { VariantFrame(variant, width, content) } }
    Variant.entries.forEach { v ->
        variant = v
        waitForIdle()
        onRoot().captureRoboImage("src/test/screenshots/$name-${v.suffix}.png", roborazziOptions = options)
    }
}

/** One full-screen capture, for screen states. */
fun ComposeContentTestRule.captureScreen(name: String, variant: Variant = Variant.LIGHT, content: @Composable () -> Unit) {
    fakeImages()
    setContent { VariantFrame(variant) { content() } }
    waitForIdle()
    onRoot().captureRoboImage("src/test/screenshots/$name-${variant.suffix}.png", roborazziOptions = options)
}
```

`app2/core/designsystem/src/test/resources/robolectric.properties` (copy the same file into every module with screenshot or Compose tests):

```properties
sdk=36
```

If Robolectric 4.17 reports that it does not support SDK 36, set `sdk=35` in every copy; the screenshots do not depend on the API level.

- [ ] **Step 8: Write the theme and symbol tests**

`ThemeScreenshotTest.kt`, a swatch of the roles the system uses, so a wrong colour or font shows in review:

```kotlin
package vn.shopnexus.core.designsystem

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import vn.shopnexus.core.designsystem.component.ShopNexusLoading
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.core.designsystem.theme.Corners
import vn.shopnexus.core.designsystem.theme.ShopNexusTheme
import vn.shopnexus.core.testing.captureVariants

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w412dp-h915dp-xhdpi")
class ThemeScreenshotTest {
    @get:Rule val compose = createComposeRule()

    @Composable
    private fun Swatch(color: Color) = Row(Modifier.size(40.dp).background(color, Corners.Medium)) {}

    @Test
    fun theme() = compose.captureVariants("theme") {
        val c = MaterialTheme.colorScheme
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(c.primary, c.primaryContainer, c.secondaryContainer, c.tertiary,
                    ShopNexusTheme.extended.tertiaryFixed, c.surfaceContainerHigh, c.error).forEach { Swatch(it) }
            }
            Text("10.900.000 ₫", style = MaterialTheme.typography.displaySmall)
            Text("Gần bạn", style = MaterialTheme.typography.headlineSmall)
            Text("iPhone 13 Pro 128GB, Xanh Sierra, pin 88%", style = MaterialTheme.typography.titleLarge)
            Text("Gặp mặt không có bảo vệ tiền. Kiểm theo danh sách rồi mới trả.", style = MaterialTheme.typography.bodyMedium)
            Text("Rẻ hơn 13%", style = MaterialTheme.typography.labelMedium, color = c.tertiary)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                SymbolIcon(Symbol.Home, null, filled = true)
                SymbolIcon(Symbol.Handshake, null)
                SymbolIcon(Symbol.AutoAwesome, null, filled = true, tint = c.primary)
                SymbolIcon(Symbol.QrCodeScanner, null)
                ShopNexusLoading()
            }
        }
    }
}
```

`SymbolsTest.kt`:

```kotlin
package vn.shopnexus.core.designsystem

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.vector

class SymbolsTest {
    @Test
    fun everySymbolBuildsAndFilledFallsBackToOutline() {
        Symbol.entries.forEach { assertThat(it.vector().root.size).isGreaterThan(0) }
        assertThat(Symbol.Home.vector(filled = true).name).isEqualTo("home.fill")
        assertThat(Symbol.Gavel.vector(filled = true).name).isEqualTo("gavel")
    }

    @Test
    fun namesFromTheDataResolve() {
        listOf("familiar_face_and_zone", "battery_full_alt", "cloud_off", "pin", "photo_camera", "mobile",
            "phone_android", "laptop_chromebook", "apparel", "two_wheeler", "chair", "blender", "stroller",
            "sports_tennis", "event_available", "undo", "star", "check_circle").forEach {
            assertThat(Symbol.of(it)).isNotNull()
        }
    }
}
```

- [ ] **Step 9: Run the tests, record the screenshots and look at them**

Run: `./gradlew :core:designsystem:testDebugUnitTest`
Expected: PASS, 3 tests.

Run: `./gradlew :core:designsystem:recordRoborazziDebug`
Expected: four files `core/designsystem/src/test/screenshots/theme-{light,dark,dynamic,font130}.png`. Open them: the light swatch row reads teal, teal, pale teal, terracotta, pale peach, grey, red; the text is Be Vietnam Pro with correct Vietnamese accents; the dynamic variant is the sample brown scheme; the font130 text is visibly larger and still on one line where it fits.

Run: `./gradlew :core:designsystem:verifyRoborazziDebug`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add build-logic settings.gradle.kts core/designsystem core/testing
git commit -m "feat(designsystem): add the theme, Be Vietnam Pro, Material Symbols and the screenshot harness

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Listing and price components

The listing card and its two layouts, the section header, the AI sparkle line, the large price figure and the amount stepper.

**Files:**
- Create in `app2/core/designsystem/src/main/kotlin/vn/shopnexus/core/designsystem/component/`: `Price.kt`, `Sparkle.kt`, `ListingCard.kt`, `SectionHeader.kt`, `AmountStepper.kt`
- Modify: `app2/core/designsystem/src/main/res/values/strings.xml`
- Test: `app2/core/designsystem/src/test/kotlin/vn/shopnexus/core/designsystem/ListingComponentsTest.kt`
- Test: `app2/core/designsystem/src/test/kotlin/vn/shopnexus/core/designsystem/AmountStepperTest.kt`

**Interfaces:**
- Consumes: Task 13 theme, `SymbolIcon`; `ListingSummary`, `PriceInsight`, `Condition`, `Vnd`, `cardParts()`, `digits()` (Tasks 3, 10); `OfferRange`, `OfferCheck` (Task 5).
- Produces:
  ```kotlin
  @Composable fun conditionLabel(condition: Condition): String          // "Mới", "Như mới", "Đã dùng"
  @Composable fun distanceLabel(km: Double): String                     // "1,6 km"
  @Composable fun PriceText(price: Vnd, modifier: Modifier = Modifier)   // card price, unit one size down
  @Composable fun TextStyle.capFontScale(max: Float = 1.15f): TextStyle   // large figures stop growing past 1.15
  @Composable fun Figure(amount: Vnd, modifier: Modifier = Modifier, color: Color = MaterialTheme.colorScheme.onSurface)
  @Composable fun SparkleLabel(text: String, modifier: Modifier = Modifier, priceTalk: Boolean = false, maxLines: Int = 1)
  @Composable fun insightText(insight: PriceInsight): String              // "Rẻ hơn 13%"
  @Composable fun ListingCard(listing: ListingSummary, onOpen: () -> Unit, onToggleSave: () -> Unit, modifier: Modifier = Modifier, showSave: Boolean = true)
  @Composable fun SaveToggle(saved: Boolean, onToggle: () -> Unit, modifier: Modifier = Modifier)
  @Composable fun ListingCardSkeleton(modifier: Modifier = Modifier)
  @Composable fun ListingRail(listings: List<ListingSummary>, onOpen: (ListingSummary) -> Unit, onToggleSave: (ListingSummary) -> Unit,
                              modifier: Modifier = Modifier, state: LazyListState = rememberLazyListState(), showSave: Boolean = true)
  fun LazyListScope.listingGrid(listings: List<ListingSummary>, onOpen: (ListingSummary) -> Unit, onToggleSave: (ListingSummary) -> Unit, skeletons: Int = 0)
  @Composable fun SectionHeader(title: String, onSeeAll: (() -> Unit)?, modifier: Modifier = Modifier)
  @Composable fun AmountStepper(amount: Vnd?, range: OfferRange, onStep: (up: Boolean) -> Unit, onType: (String) -> Unit, modifier: Modifier = Modifier)
  @Composable fun offerCheckText(check: OfferCheck): String                // "−100.000 ₫", "Từ 5.500.000 ₫ trở lên", …
  ```

- [ ] **Step 1: Add the strings**

Add to `strings.xml`:

```xml
    <string name="condition_new">Mới</string>
    <string name="condition_like_new">Như mới</string>
    <string name="condition_used">Đã dùng</string>
    <string name="distance_km">%1$s km</string>
    <string name="meta_line">%1$s · %2$s</string>
    <string name="insight_cheaper">Rẻ hơn %1$d%%</string>
    <string name="insight_pricier">Cao hơn %1$d%%</string>
    <string name="save_listing">Lưu tin</string>
    <string name="open_listing">Xem %1$s</string>
    <string name="see_all">Xem tất cả %1$s</string>
    <string name="decrease_by">Giảm %1$s</string>
    <string name="increase_by">Tăng %1$s</string>
    <string name="offer_amount">Giá bạn đề nghị</string>
    <string name="offer_gap">−%1$s</string>
    <string name="offer_too_low">Từ %1$s trở lên</string>
    <string name="offer_not_below">Thấp hơn %1$s. Bằng giá này thì bấm Đồng ý.</string>
    <string name="offer_empty">Nhập số tiền</string>
```

- [ ] **Step 2: Write the failing behaviour tests**

`AmountStepperTest.kt`:

```kotlin
package vn.shopnexus.core.designsystem

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import vn.shopnexus.core.designsystem.component.AmountStepper
import vn.shopnexus.core.designsystem.theme.ShopNexusTheme
import vn.shopnexus.core.domain.offerRange
import vn.shopnexus.core.domain.parseOfferInput
import vn.shopnexus.core.model.Vnd

@RunWith(AndroidJUnit4::class)
class AmountStepperTest {
    @get:Rule val compose = createComposeRule()
    private val range = offerRange(Vnd(10_900_000), Vnd(10_600_000))

    @Test
    fun plusStopsBelowTheCounterAndTypingKeepsOnlyDigits() {
        var amount by mutableStateOf<Vnd?>(Vnd(10_400_000))
        compose.setContent {
            ShopNexusTheme {
                AmountStepper(
                    amount = amount, range = range,
                    onStep = { up -> amount = range.stepped(amount ?: range.highest, up) },
                    onType = { amount = parseOfferInput(it) },
                )
            }
        }
        compose.onNodeWithContentDescription("Tăng 100.000 ₫").performClick()
        compose.onNodeWithText("10.500.000").assertExists()
        compose.onNodeWithContentDescription("Tăng 100.000 ₫").assertIsNotEnabled()
        compose.onNodeWithContentDescription("Giảm 100.000 ₫").assertIsEnabled()
        compose.onNodeWithContentDescription("Giá bạn đề nghị").performTextReplacement("10,3tr")
        assertThat(amount).isEqualTo(Vnd(103))
        compose.onNodeWithContentDescription("Giá bạn đề nghị").performTextReplacement("")
        assertThat(amount).isNull()
    }
}
```

The test pins Review Focus 1 on the control: "10,3tr" keeps only its digits ("103"), which the range then rejects as too low; an empty field is no amount.

`ListingComponentsTest.kt`:

```kotlin
package vn.shopnexus.core.designsystem

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.layout.height
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import vn.shopnexus.core.designsystem.component.Figure
import vn.shopnexus.core.designsystem.component.ListingCard
import vn.shopnexus.core.designsystem.component.ListingRail
import vn.shopnexus.core.designsystem.component.SectionHeader
import vn.shopnexus.core.designsystem.component.SparkleLabel
import vn.shopnexus.core.designsystem.component.listingGrid
import vn.shopnexus.core.designsystem.theme.ShopNexusTheme
import vn.shopnexus.core.model.Condition
import vn.shopnexus.core.model.ListingId
import vn.shopnexus.core.model.ListingSummary
import vn.shopnexus.core.model.PriceDirection
import vn.shopnexus.core.model.PriceInsight
import vn.shopnexus.core.model.Vnd
import vn.shopnexus.core.testing.captureVariants

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w412dp-h915dp-xhdpi")
class ListingComponentsTest {
    @get:Rule val compose = createComposeRule()

    private val iphone = ListingSummary(
        ListingId("p-iphone13"), "", Vnd(10_900_000), "iPhone 13 Pro 128GB, Xanh Sierra, pin 88%, máy zin chưa sửa chữa lần nào",
        Condition.LIKE_NEW, 1.6, PriceInsight(PriceDirection.CHEAPER, 13),
    )
    private val bike = ListingSummary(ListingId("l-2"), "", Vnd(2_300_000), "Xe đạp fixed gear khung thép", Condition.USED, 1.4, saved = true)

    @Test
    fun cardShowsShortPriceInsightTitleAndMeta() {
        compose.setContent { ShopNexusTheme { ListingCard(iphone, onOpen = {}, onToggleSave = {}) } }
        compose.onNodeWithText("10,9", substring = true).assertExists()
        compose.onNodeWithText("Rẻ hơn 13%").assertExists()
        compose.onNodeWithText("Như mới · 1,6 km").assertExists()
        compose.onAllNodesWithContentDescription("Lưu tin").onFirst().assertIsOff()
    }

    @Test
    fun savedCardShowsTheFilledHeart() {
        compose.setContent { ShopNexusTheme { ListingCard(bike, onOpen = {}, onToggleSave = {}) } }
        compose.onNodeWithText("2.300.000", substring = true).assertExists()
        compose.onAllNodesWithContentDescription("Lưu tin").onFirst().assertIsOn()
    }

    @Test
    fun screenshots() = compose.captureVariants("listing-components") {
        Column(Modifier.padding(vertical = 16.dp)) {
            SectionHeader("Gần bạn", onSeeAll = {})
            ListingRail(listOf(iphone, bike, iphone), onOpen = {}, onToggleSave = {})
            SectionHeader("Gợi ý cho bạn", onSeeAll = {})
            LazyColumn(Modifier.height(420.dp)) { listingGrid(listOf(bike, iphone), onOpen = {}, onToggleSave = {}, skeletons = 2) }
            SparkleLabel("Rẻ hơn 13% so với tin tương tự", priceTalk = true, modifier = Modifier.padding(16.dp))
            Figure(Vnd(10_600_000), Modifier.padding(horizontal = 16.dp))
        }
    }
}
```

The photo URLs are empty, so Coil shows the `surfaceContainerHigh` placeholder and the screenshots never touch the network.

- [ ] **Step 3: Run them to verify they fail**

Run: `./gradlew :core:designsystem:testDebugUnitTest`
Expected: FAIL, `Unresolved reference 'AmountStepper'`, `'ListingCard'`.

- [ ] **Step 4: Write the price and sparkle pieces**

`Price.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import vn.shopnexus.core.designsystem.R
import vn.shopnexus.core.model.Condition
import vn.shopnexus.core.model.Vnd
import vn.shopnexus.core.model.cardParts
import vn.shopnexus.core.model.digits

@Composable
fun conditionLabel(condition: Condition): String = stringResource(
    when (condition) {
        Condition.NEW -> R.string.condition_new
        Condition.LIKE_NEW -> R.string.condition_like_new
        Condition.USED -> R.string.condition_used
    },
)

@Composable
fun distanceLabel(km: Double): String = stringResource(R.string.distance_km, "%.1f".format(km).replace('.', ','))

/** A card price: "10,9" with " tr ₫", or "2.300.000" with " ₫", the unit one size down. */
@Composable
fun PriceText(price: Vnd, modifier: Modifier = Modifier) {
    val (number, unit) = price.cardParts()
    val unitStyle = MaterialTheme.typography.bodyMedium
    Text(
        buildAnnotatedString {
            append(number)
            withStyle(SpanStyle(fontSize = unitStyle.fontSize, color = MaterialTheme.colorScheme.onSurfaceVariant)) { append(unit) }
        },
        modifier = modifier,
        style = MaterialTheme.typography.titleMedium,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

/**
 * Large figures start at 36 sp. Past a font scale of 1.15 they stop growing, so an amount stays on one
 * line between the stepper buttons; body text keeps scaling as the person set it.
 */
@Composable
fun TextStyle.capFontScale(max: Float = 1.15f): TextStyle {
    val scale = LocalDensity.current.fontScale
    if (scale <= max) return this
    val k = max / scale
    return copy(fontSize = fontSize * k, lineHeight = lineHeight * k)
}

/** A large light figure: displaySmall digits with the ₫ at titleLarge in onSurfaceVariant. */
@Composable
fun Figure(amount: Vnd, modifier: Modifier = Modifier, color: Color = MaterialTheme.colorScheme.onSurface) {
    val unit = MaterialTheme.typography.titleLarge.capFontScale()
    Text(
        buildAnnotatedString {
            append(amount.digits())
            withStyle(SpanStyle(fontSize = unit.fontSize, color = MaterialTheme.colorScheme.onSurfaceVariant)) { append("\u00A0₫") }
        },
        modifier = modifier,
        style = MaterialTheme.typography.displaySmall.capFontScale(),
        color = color,
        maxLines = 1,
    )
}
```

`Sparkle.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import vn.shopnexus.core.designsystem.R
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.core.model.PriceDirection
import vn.shopnexus.core.model.PriceInsight

/** An AI judgment: the filled sparkle and a label. Price talk is terracotta, everything else teal. */
@Composable
fun SparkleLabel(text: String, modifier: Modifier = Modifier, priceTalk: Boolean = false, maxLines: Int = 1) {
    val color = if (priceTalk) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.primary
    Row(
        modifier,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = if (maxLines == 1) Alignment.CenterVertically else Alignment.Top,
    ) {
        SymbolIcon(Symbol.AutoAwesome, contentDescription = null, filled = true, size = 14.dp, tint = color, modifier = Modifier.padding(top = if (maxLines == 1) 0.dp else 1.dp))
        Text(text, style = MaterialTheme.typography.labelMedium, color = color, maxLines = maxLines, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
fun insightText(insight: PriceInsight): String = when (insight.direction) {
    PriceDirection.CHEAPER -> stringResource(R.string.insight_cheaper, insight.percent)
    PriceDirection.PRICIER -> stringResource(R.string.insight_pricier, insight.percent)
}
```

- [ ] **Step 5: Write the card, its layouts and the section header**

`ListingCard.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.gestures.snapping.SnapPosition
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.IconToggleButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import vn.shopnexus.core.designsystem.R
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.core.designsystem.theme.Corners
import vn.shopnexus.core.model.ListingSummary

/** The one listing card: square photo, price with the save toggle, the AI price line, two-line title, meta. */
@Composable
fun ListingCard(listing: ListingSummary, onOpen: () -> Unit, onToggleSave: () -> Unit, modifier: Modifier = Modifier, showSave: Boolean = true) {
    val openLabel = stringResource(R.string.open_listing, listing.title)
    Column(modifier) {
        AsyncImage(
            model = listing.photoUrl,
            contentDescription = openLabel,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
                .clip(Corners.LargeIncreased)
                .background(MaterialTheme.colorScheme.surfaceContainerHigh)
                .clickable(onClick = onOpen),
        )
        Row(Modifier.padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            PriceText(listing.price, Modifier.weight(1f))
            if (showSave) SaveToggle(listing.saved, onToggleSave, Modifier.offset(x = 12.dp))
        }
        listing.insight?.takeIf { it.percent >= 10 }?.let { SparkleLabel(insightText(it), priceTalk = true) }
        Text(
            listing.title,
            style = MaterialTheme.typography.bodyMedium,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 2.dp),
        )
        Text(
            stringResource(R.string.meta_line, conditionLabel(listing.condition), distanceLabel(listing.distanceKm)),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 4.dp),
        )
    }
}

/** Outline heart off, filled primary heart on; a 48 dp target around a 22 dp icon. */
@Composable
fun SaveToggle(saved: Boolean, onToggle: () -> Unit, modifier: Modifier = Modifier) {
    val label = stringResource(R.string.save_listing)
    IconToggleButton(
        checked = saved,
        onCheckedChange = { onToggle() },
        modifier = modifier.size(48.dp).semantics { contentDescription = label },
        colors = IconButtonDefaults.iconToggleButtonColors(
            contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
            checkedContentColor = MaterialTheme.colorScheme.primary,
        ),
    ) {
        SymbolIcon(Symbol.Favorite, contentDescription = null, filled = saved, size = 22.dp)
    }
}

/** The card's exact shape in surfaceContainerHigh while a feed loads. */
@Composable
fun ListingCardSkeleton(modifier: Modifier = Modifier) {
    val fill = MaterialTheme.colorScheme.surfaceContainerHigh
    Column(modifier.clearAndSetSemantics {}) {
        Box(Modifier.fillMaxWidth().aspectRatio(1f).background(fill, Corners.LargeIncreased))
        Box(Modifier.padding(top = 12.dp).width(96.dp).height(16.dp).background(fill, CircleShape))
        Box(Modifier.padding(top = 8.dp).fillMaxWidth().height(14.dp).background(fill, CircleShape))
        Box(Modifier.padding(top = 8.dp).fillMaxWidth(0.5f).height(12.dp).background(fill, CircleShape))
    }
}

/** A horizontal row of 160 dp cards, 12 dp apart, snapping to the start. */
@Composable
fun ListingRail(
    listings: List<ListingSummary>,
    onOpen: (ListingSummary) -> Unit,
    onToggleSave: (ListingSummary) -> Unit,
    modifier: Modifier = Modifier,
    state: LazyListState = rememberLazyListState(),
    showSave: Boolean = true,
) {
    LazyRow(
        modifier = modifier,
        state = state,
        contentPadding = PaddingValues(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        flingBehavior = rememberSnapFlingBehavior(state, SnapPosition.Start),
    ) {
        items(listings, key = { it.id.value }) { listing ->
            ListingCard(listing, { onOpen(listing) }, { onToggleSave(listing) }, Modifier.width(160.dp).animateItem(), showSave)
        }
    }
}

/** Two aligned columns, 12 dp apart, 24 dp between rows, inside a LazyColumn. */
fun LazyListScope.listingGrid(
    listings: List<ListingSummary>,
    onOpen: (ListingSummary) -> Unit,
    onToggleSave: (ListingSummary) -> Unit,
    skeletons: Int = 0,
) {
    val cells: List<ListingSummary?> = listings + List(skeletons) { null }
    val rows = cells.chunked(2)
    items(rows.size, key = { i -> rows[i].joinToString { it?.id?.value ?: "skeleton-$i" } }) { i ->
        Row(
            Modifier.padding(start = 16.dp, end = 16.dp, bottom = 24.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            rows[i].forEach { cell ->
                if (cell == null) ListingCardSkeleton(Modifier.weight(1f))
                else ListingCard(cell, { onOpen(cell) }, { onToggleSave(cell) }, Modifier.weight(1f))
            }
            if (rows[i].size == 1) Spacer(Modifier.weight(1f))
        }
    }
}
```

`SectionHeader.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import vn.shopnexus.core.designsystem.R
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon

/** A headlineSmall title and, at the right, an arrow in a 36 dp circle that opens the full list. */
@Composable
fun SectionHeader(title: String, onSeeAll: (() -> Unit)?, modifier: Modifier = Modifier) {
    Row(
        modifier.padding(start = 16.dp, end = 12.dp, top = 32.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            title,
            style = MaterialTheme.typography.headlineSmall,
            modifier = Modifier.weight(1f).semantics { heading() },
            maxLines = 1,
        )
        if (onSeeAll != null) {
            IconButton(onClick = onSeeAll) {
                Box(Modifier.size(36.dp).background(MaterialTheme.colorScheme.surfaceContainerHigh, CircleShape), Alignment.Center) {
                    SymbolIcon(
                        Symbol.ArrowForward,
                        contentDescription = stringResource(R.string.see_all, title),
                        size = 20.dp,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}
```

- [ ] **Step 6: Write the amount stepper**

`AmountStepper.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import vn.shopnexus.core.designsystem.R
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.core.domain.OfferCheck
import vn.shopnexus.core.domain.OfferRange
import vn.shopnexus.core.model.Vnd
import vn.shopnexus.core.model.digits
import vn.shopnexus.core.model.full

/**
 * − / amount / +: a light displaySmall figure between 48 dp buttons that step by [OfferRange.step].
 * Typing is allowed; the caller parses the text, so separators and letters never reach the amount.
 */
@Composable
fun AmountStepper(
    amount: Vnd?,
    range: OfferRange,
    onStep: (up: Boolean) -> Unit,
    onType: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val step = range.step.full()
    val buttons = IconButtonDefaults.filledIconButtonColors(
        containerColor = MaterialTheme.colorScheme.surfaceContainerHighest,
        contentColor = MaterialTheme.colorScheme.onSurface,
    )
    val fieldLabel = stringResource(R.string.offer_amount)
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
        FilledIconButton(
            onClick = { onStep(false) },
            enabled = amount == null || amount - range.step >= range.floor,
            colors = buttons,
            modifier = Modifier.size(48.dp),
        ) { SymbolIcon(Symbol.Remove, stringResource(R.string.decrease_by, step)) }
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.Bottom) {
            BasicTextField(
                value = amount?.digits() ?: "",
                onValueChange = onType,
                singleLine = true,
                textStyle = MaterialTheme.typography.displaySmall.capFontScale()
                    .copy(color = MaterialTheme.colorScheme.onSurface, textAlign = TextAlign.End),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                modifier = Modifier.width(IntrinsicSize.Min).widthIn(min = 48.dp).semantics { contentDescription = fieldLabel },
            )
            Text(
                "\u00A0₫",
                style = MaterialTheme.typography.titleLarge.capFontScale(),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        FilledIconButton(
            onClick = { onStep(true) },
            enabled = amount == null || amount + range.step <= range.highest,
            colors = buttons,
            modifier = Modifier.size(48.dp),
        ) { SymbolIcon(Symbol.Add, stringResource(R.string.increase_by, step)) }
    }
}

/** The line under the amount: the gap to the counter, or why the amount cannot be sent. */
@Composable
fun offerCheckText(check: OfferCheck): String = when (check) {
    OfferCheck.Empty -> stringResource(R.string.offer_empty)
    is OfferCheck.TooLow -> stringResource(R.string.offer_too_low, check.floor.full())
    is OfferCheck.NotBelow -> stringResource(R.string.offer_not_below, check.ceiling.full())
    is OfferCheck.Ok -> stringResource(R.string.offer_gap, check.gap.full())
}
```

`:core:designsystem` now uses `:core:domain`; change `api(project(":core:model"))` in its build file to `api(project(":core:domain"))`, which brings `:core:model` with it.

- [ ] **Step 7: Run the tests, record and review the screenshots**

Run: `./gradlew :core:designsystem:testDebugUnitTest`
Expected: PASS, 7 tests.

Run: `./gradlew :core:designsystem:recordRoborazziDebug`, then open `listing-components-*.png` next to `app2/.superdesign/tmp/home.html` in a browser at 412 px. Check: cards are photo-first with no container, the price is one line with its smaller unit, "Rẻ hơn 13%" is terracotta with the sparkle, the heart sits at the right edge, titles clamp at two lines, the arrow sits in a 36 dp grey circle. At font130 the long title still clamps at two lines and the price ellipsizes rather than pushing the heart out.

Run: `./gradlew :core:designsystem:verifyRoborazziDebug`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add core/designsystem
git commit -m "feat(designsystem): add the listing card, rail, grid, section header, figure and amount stepper

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: Deal components

The pieces a deal is drawn with: the phase stepper, money sentences, milestones, the tier chip, the condition scale, the declared mark row and the grouped list.

**Files:**
- Create in `app2/core/designsystem/src/main/kotlin/vn/shopnexus/core/designsystem/component/`: `PhaseStepper.kt`, `MoneyNote.kt`, `Milestone.kt`, `TierChip.kt`, `Condition.kt`, `GroupedList.kt`
- Modify: `app2/core/designsystem/src/main/res/values/strings.xml`
- Test: `app2/core/designsystem/src/test/kotlin/vn/shopnexus/core/designsystem/DealComponentsTest.kt`

**Interfaces:**
- Consumes: Task 13 theme; `MoneyKey`, `Tier`, `Condition`, `DeclaredMark`, `MilestoneKind`, `HandoverPath` (Task 3).
- Produces:
  ```kotlin
  enum class PhaseSet { MEET, COD }
  @Composable fun PhaseStepper(current: Int, set: PhaseSet, modifier: Modifier = Modifier, small: Boolean = false) // current 0..4, 4 = all done
  @Composable fun moneyText(key: MoneyKey): String
  @Composable fun MoneyNote(key: MoneyKey, modifier: Modifier = Modifier)
  enum class MilestoneTone { DEAL, TRUST, CALM }
  @Composable fun rememberReducedMotion(): Boolean                       // "Remove animations" is on
  @Composable fun Milestone(shape: RoundedPolygon, tone: MilestoneTone, icon: Symbol, title: String, line: String,
                            modifier: Modifier = Modifier, size: Dp = 96.dp, animate: Boolean = true)
  @Composable fun tierLabel(tier: Tier): String                          // Mới, Tin cậy, Uy tín, Xuất sắc
  @Composable fun TierChip(tier: Tier, modifier: Modifier = Modifier, onClick: (() -> Unit)? = null)
  @Composable fun ConditionScale(level: Condition, modifier: Modifier = Modifier)
  @Composable fun DeclaredMarkRow(mark: DeclaredMark, capturedLabel: String, onOpen: () -> Unit, modifier: Modifier = Modifier)
  @Composable fun GroupedList(modifier: Modifier = Modifier, title: String? = null, content: GroupScope.() -> Unit)
  class GroupScope { fun row(key: Any, content: @Composable () -> Unit) }
  @Composable fun GroupRow(title: String, modifier: Modifier = Modifier, supporting: String? = null, leading: Symbol? = null,
                           trailing: @Composable (() -> Unit)? = null, enabled: Boolean = true, onClick: (() -> Unit)? = null)
  ```

- [ ] **Step 1: Add the strings**

The money sentences come word for word from `MONEY` in `.superdesign/tools/common.py`; every screen shows them through `MoneyNote`, so the words stay the same everywhere.

```xml
    <string name="money_meet">Gặp mặt không có bảo vệ tiền. Kiểm theo danh sách rồi mới trả.</string>
    <string name="money_over_limit">Món trên 5 triệu chỉ giao dịch gặp mặt.</string>
    <string name="money_no_hold">ShopNexus không giữ tiền và không nhận cọc.</string>
    <string name="money_after_pay">Đã trả tiền thì ShopNexus không đòi lại được. Có vấn đề, mở ghi nhận để người bán tự hoàn.</string>
    <string name="money_declared">Vết đã khai không được lấy làm lý do khiếu nại. Vết không khai mà hàng có thì lỗi thuộc người bán.</string>
    <string name="money_cod_buyer">Phí ship trả trước, không hoàn. Tiền hàng trả cho shipper sau khi xem hàng.</string>
    <string name="money_refuse">Không ưng thì từ chối nhận: hàng quay về, bạn chỉ mất phí ship.</string>
    <string name="money_handover">Người bán chưa gửi hàng trong 48 giờ thì phí ship tự hoàn cho bạn.</string>
    <string name="money_cod_seller">Tiền hàng do bên vận chuyển chuyển cho bạn sau khi người mua nhận, thường 1–2 ngày.</string>
    <string name="money_return_leg">Người mua từ chối nhận thì bạn trả phí ship chiều về.</string>
    <string name="phase_negotiate">Thương lượng</string>
    <string name="phase_arrange">Hẹn gặp</string>
    <string name="phase_meet">Gặp và kiểm</string>
    <string name="phase_ship">Gửi hàng</string>
    <string name="phase_receive">Xem và nhận</string>
    <string name="phase_rate">Đánh giá</string>
    <string name="phase_step">Bước %1$d trên %2$d: %3$s</string>
    <string name="phase_all_done">Đã xong cả %1$d bước</string>
    <string name="tier_new">Mới</string>
    <string name="tier_trusted">Tin cậy</string>
    <string name="tier_reputable">Uy tín</string>
    <string name="tier_top">Xuất sắc</string>
    <string name="condition_new_meaning">Chưa dùng, còn seal hoặc đủ hộp</string>
    <string name="condition_like_new_meaning">Không vết, hoặc vết rất nhỏ chỉ thấy khi soi gần</string>
    <string name="condition_used_meaning">Có vết thấy rõ hoặc lỗi nhỏ</string>
    <string name="open_close_up">Xem ảnh cận %1$s</string>
```

- [ ] **Step 2: Write the failing test**

`DealComponentsTest.kt`:

```kotlin
package vn.shopnexus.core.designsystem

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.Switch
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import vn.shopnexus.core.designsystem.component.ConditionScale
import vn.shopnexus.core.designsystem.component.DeclaredMarkRow
import vn.shopnexus.core.designsystem.component.GroupRow
import vn.shopnexus.core.designsystem.component.GroupedList
import vn.shopnexus.core.designsystem.component.Milestone
import vn.shopnexus.core.designsystem.component.MilestoneTone
import vn.shopnexus.core.designsystem.component.MoneyNote
import vn.shopnexus.core.designsystem.component.PhaseSet
import vn.shopnexus.core.designsystem.component.PhaseStepper
import vn.shopnexus.core.designsystem.component.TierChip
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.theme.ShopNexusTheme
import vn.shopnexus.core.model.Condition
import vn.shopnexus.core.model.DeclaredMark
import vn.shopnexus.core.model.MoneyKey
import vn.shopnexus.core.model.Photo
import vn.shopnexus.core.model.PhotoSource
import vn.shopnexus.core.model.Tier
import vn.shopnexus.core.testing.captureVariants

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w412dp-h915dp-xhdpi")
class DealComponentsTest {
    @get:Rule val compose = createComposeRule()
    private val mark = DeclaredMark("2 vết xước nhỏ ở viền", Photo("", PhotoSource.APP))

    @Test
    fun stepperNamesTheCurrentPhase() {
        compose.setContent { ShopNexusTheme { PhaseStepper(current = 1, set = PhaseSet.MEET) } }
        compose.onNodeWithContentDescription("Bước 2 trên 4: Hẹn gặp").assertExists()
    }

    @Test
    fun moneyNoteUsesTheSharedWords() {
        compose.setContent { ShopNexusTheme { MoneyNote(MoneyKey.MEET) } }
        compose.onNodeWithText("Gặp mặt không có bảo vệ tiền. Kiểm theo danh sách rồi mới trả.").assertExists()
    }

    @Test
    fun groupRowsAreAtLeast72dpTall() {
        compose.setContent { ShopNexusTheme { GroupedList { row("a") { GroupRow("Gặp mặt", supporting = "Bình Thạnh · sau 18:00") } } } }
        compose.onNodeWithText("Gặp mặt").assertExists()
        compose.onNodeWithContentDescription("Gặp mặt, Bình Thạnh · sau 18:00").assertHeightIsAtLeast(72.dp)
    }

    @Test
    fun screenshots() = compose.captureVariants("deal-components") {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            PhaseStepper(current = 1, set = PhaseSet.MEET)
            PhaseStepper(current = 2, set = PhaseSet.COD, small = true)
            MoneyNote(MoneyKey.AFTER_PAY)
            Milestone(MaterialShapes.Cookie9Sided, MilestoneTone.DEAL, Symbol.Handshake, "Chốt 10,6 tr", "Bắt tay rồi! Giờ hẹn gặp để xem máy nhé.", animate = false)
            TierChip(Tier.TOP)
            ConditionScale(Condition.LIKE_NEW)
            DeclaredMarkRow(mark, "Ảnh cận chụp trong app · 12/10", onOpen = {})
            GroupedList(title = "Giao dịch") {
                row("meet") { GroupRow("Gặp mặt", supporting = "Bình Thạnh · sau 18:00", leading = Symbol.Handshake) }
                row("cod") { GroupRow("COD, xem hàng trước", supporting = "Món trên 5 triệu chỉ giao dịch gặp mặt.", leading = Symbol.LocalShipping, enabled = false, trailing = { Switch(false, null, enabled = false) }) }
            }
        }
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `./gradlew :core:designsystem:testDebugUnitTest --tests "*DealComponentsTest*"`
Expected: FAIL, unresolved references.

- [ ] **Step 4: Write the stepper, money note and milestone**

`PhaseStepper.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.toShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import vn.shopnexus.core.designsystem.R
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon

enum class PhaseSet { MEET, COD }

private data class Phase(val name: Int, val icon: Symbol)

private val meetPhases = listOf(
    Phase(R.string.phase_negotiate, Symbol.Handshake), Phase(R.string.phase_arrange, Symbol.Event),
    Phase(R.string.phase_meet, Symbol.QrCodeScanner), Phase(R.string.phase_rate, Symbol.Star),
)
private val codPhases = listOf(
    Phase(R.string.phase_negotiate, Symbol.Handshake), Phase(R.string.phase_ship, Symbol.LocalShipping),
    Phase(R.string.phase_receive, Symbol.PackageTwo), Phase(R.string.phase_rate, Symbol.Star),
)

/**
 * Four icons joined by 2 dp lines. Done phases are a check on primary, the current one sits in a
 * Cookie9Sided shape in primaryContainer, later ones are outline icons. Names live in the accessible label only.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun PhaseStepper(current: Int, set: PhaseSet, modifier: Modifier = Modifier, small: Boolean = false) {
    val phases = if (set == PhaseSet.MEET) meetPhases else codPhases
    val label = if (current < phases.size) {
        stringResource(R.string.phase_step, current + 1, phases.size, stringResource(phases[current].name))
    } else {
        stringResource(R.string.phase_all_done, phases.size)
    }
    val dot = if (small) 32.dp else 40.dp
    val iconSize = if (small) 16.dp else 20.dp
    val c = MaterialTheme.colorScheme
    Row(modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = label }, verticalAlignment = Alignment.CenterVertically) {
        phases.forEachIndexed { i, phase ->
            if (i > 0) {
                val line by animateColorAsState(if (i <= current) c.primary else c.outlineVariant, label = "line")
                Box(Modifier.weight(1f).padding(horizontal = if (small) 4.dp else 6.dp).height(2.dp).background(line, RoundedCornerShape(1.dp)))
            }
            Box(Modifier.size(dot), contentAlignment = Alignment.Center) {
                when {
                    i < current -> {
                        Box(Modifier.size(dot).background(c.primary, CircleShape))
                        SymbolIcon(Symbol.Check, null, size = iconSize, tint = c.onPrimary)
                    }
                    i == current -> {
                        Box(Modifier.requiredSize(dot + 8.dp).background(c.primaryContainer, MaterialShapes.Cookie9Sided.toShape()))
                        SymbolIcon(phase.icon, null, size = iconSize, tint = c.onPrimaryContainer)
                    }
                    else -> {
                        Box(Modifier.size(dot).background(c.surfaceContainerHighest, CircleShape))
                        SymbolIcon(phase.icon, null, size = iconSize, tint = c.onSurfaceVariant)
                    }
                }
            }
        }
    }
}
```

`MoneyNote.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import vn.shopnexus.core.designsystem.R
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.core.model.MoneyKey

@Composable
fun moneyText(key: MoneyKey): String = stringResource(
    when (key) {
        MoneyKey.MEET -> R.string.money_meet
        MoneyKey.OVER_LIMIT -> R.string.money_over_limit
        MoneyKey.NO_HOLD -> R.string.money_no_hold
        MoneyKey.AFTER_PAY -> R.string.money_after_pay
        MoneyKey.DECLARED -> R.string.money_declared
        MoneyKey.COD_BUYER -> R.string.money_cod_buyer
        MoneyKey.REFUSE -> R.string.money_refuse
        MoneyKey.HANDOVER -> R.string.money_handover
        MoneyKey.COD_SELLER -> R.string.money_cod_seller
        MoneyKey.RETURN_LEG -> R.string.money_return_leg
    },
)

/** The icons `money_note()` uses in the mockups. */
private fun iconFor(key: MoneyKey) = when (key) {
    MoneyKey.MEET, MoneyKey.AFTER_PAY -> Symbol.Shield
    MoneyKey.OVER_LIMIT -> Symbol.Handshake
    MoneyKey.NO_HOLD -> Symbol.AccountBalance
    MoneyKey.DECLARED -> Symbol.Gavel
    else -> Symbol.Info
}

/** The one plain sentence at a step that touches money: an 18 dp icon and bodyMedium in onSurfaceVariant. */
@Composable
fun MoneyNote(key: MoneyKey, modifier: Modifier = Modifier) {
    val color = MaterialTheme.colorScheme.onSurfaceVariant
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        SymbolIcon(iconFor(key), contentDescription = null, size = 18.dp, tint = color, modifier = Modifier.padding(top = 1.dp))
        Text(moneyText(key), style = MaterialTheme.typography.bodyMedium, color = color)
    }
}
```

`Milestone.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import android.provider.Settings
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.toShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.graphics.shapes.RoundedPolygon
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.core.designsystem.theme.ShopNexusTheme

/** Terracotta for the agreed price, teal for trust, neutral for calm moments. */
enum class MilestoneTone { DEAL, TRUST, CALM }

/** Android has no separate reduce-motion switch; "Remove animations" sets the animator scale to 0. */
@Composable
fun rememberReducedMotion(): Boolean {
    val resolver = LocalContext.current.contentResolver
    return remember(resolver) { Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }
}

/**
 * A deal moment: a large MaterialShape with an icon, a titleLarge title and one line that says how it
 * feels. It springs in, rotating, unless [animate] is off (reduced motion, screenshots).
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun Milestone(
    shape: RoundedPolygon,
    tone: MilestoneTone,
    icon: Symbol,
    title: String,
    line: String,
    modifier: Modifier = Modifier,
    size: Dp = 96.dp,
    animate: Boolean = true,
) {
    val c = MaterialTheme.colorScheme
    val (fill, ink) = when (tone) {
        MilestoneTone.DEAL -> ShopNexusTheme.extended.tertiaryFixed to ShopNexusTheme.extended.onTertiaryFixedVariant
        MilestoneTone.TRUST -> c.primaryContainer to c.onPrimaryContainer
        MilestoneTone.CALM -> c.secondaryContainer to c.onSecondaryContainer
    }
    val progress = remember { Animatable(if (animate) 0f else 1f) }
    val spec = MaterialTheme.motionScheme.slowSpatialSpec<Float>()
    LaunchedEffect(Unit) { if (animate) progress.animateTo(1f, spec) }
    Column(
        modifier.fillMaxWidth().padding(vertical = 12.dp).semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier
                .size(size)
                .graphicsLayer {
                    val p = progress.value
                    scaleX = 0.3f + 0.7f * p
                    scaleY = 0.3f + 0.7f * p
                    rotationZ = -90f * (1f - p)
                    alpha = p.coerceIn(0f, 1f)
                }
                .background(fill, shape.toShape()),
            contentAlignment = Alignment.Center,
        ) {
            SymbolIcon(icon, contentDescription = null, size = size * 3 / 8, tint = ink)
        }
        Text(title, style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 12.dp))
        Text(line, style = MaterialTheme.typography.bodyMedium, color = c.onSurfaceVariant, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 4.dp))
    }
}
```

`androidx.graphics.shapes.RoundedPolygon` comes with material3 as a transitive dependency; if the import does not resolve, add `implementation("androidx.graphics:graphics-shapes:1.1.0")` to `:core:designsystem`.

- [ ] **Step 5: Write the tier chip, condition pieces and grouped list**

`TierChip.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import vn.shopnexus.core.designsystem.R
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.core.model.Tier

@Composable
fun tierLabel(tier: Tier): String = stringResource(
    when (tier) {
        Tier.NEW -> R.string.tier_new
        Tier.TRUSTED -> R.string.tier_trusted
        Tier.REPUTABLE -> R.string.tier_reputable
        Tier.TOP -> R.string.tier_top
    },
)

/** The seller's tier: a 32 dp secondaryContainer pill with the premium icon. Clickable only when [onClick] is given. */
@Composable
fun TierChip(tier: Tier, modifier: Modifier = Modifier, onClick: (() -> Unit)? = null) {
    val c = MaterialTheme.colorScheme
    val content: @Composable () -> Unit = {
        Row(
            Modifier.height(32.dp).padding(horizontal = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SymbolIcon(Symbol.WorkspacePremium, null, size = 18.dp)
            Text(tierLabel(tier), style = MaterialTheme.typography.labelLarge)
        }
    }
    if (onClick == null) {
        Surface(modifier, shape = CircleShape, color = c.secondaryContainer, contentColor = c.onSecondaryContainer, content = content)
    } else {
        Surface(onClick = onClick, modifier = modifier, shape = CircleShape, color = c.secondaryContainer, contentColor = c.onSecondaryContainer, content = content)
    }
}
```

`Condition.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import vn.shopnexus.core.designsystem.R
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.core.designsystem.theme.Corners
import vn.shopnexus.core.model.Condition
import vn.shopnexus.core.model.DeclaredMark

/** Three joined segments with 4 dp inner corners; the listing's level in secondaryContainer with a check, its meaning below. */
@Composable
fun ConditionScale(level: Condition, modifier: Modifier = Modifier) {
    val levels = Condition.entries
    val c = MaterialTheme.colorScheme
    Column(modifier) {
        Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            levels.forEachIndexed { i, l ->
                val shape = RoundedCornerShape(
                    topStart = if (i == 0) 20.dp else 4.dp, bottomStart = if (i == 0) 20.dp else 4.dp,
                    topEnd = if (i == levels.lastIndex) 20.dp else 4.dp, bottomEnd = if (i == levels.lastIndex) 20.dp else 4.dp,
                )
                val on = l == level
                Row(
                    Modifier.weight(1f).heightIn(min = 40.dp).background(if (on) c.secondaryContainer else c.surfaceContainerHigh, shape)
                        .semantics { selected = on },
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (on) SymbolIcon(Symbol.Check, null, size = 18.dp, tint = c.onSecondaryContainer, modifier = Modifier.padding(end = 4.dp))
                    Text(conditionLabel(l), style = MaterialTheme.typography.labelLarge, color = if (on) c.onSecondaryContainer else c.onSurfaceVariant)
                }
            }
        }
        Text(
            stringResource(
                when (level) {
                    Condition.NEW -> R.string.condition_new_meaning
                    Condition.LIKE_NEW -> R.string.condition_like_new_meaning
                    Condition.USED -> R.string.condition_used_meaning
                },
            ),
            style = MaterialTheme.typography.bodySmall,
            color = c.onSurfaceVariant,
            modifier = Modifier.padding(top = 8.dp),
        )
    }
}

/** A declared mark: the close-up, the text, and camera + where the close-up came from. */
@Composable
fun DeclaredMarkRow(mark: DeclaredMark, capturedLabel: String, onOpen: () -> Unit, modifier: Modifier = Modifier) {
    val c = MaterialTheme.colorScheme
    Row(
        modifier.fillMaxWidth().clip(Corners.ExtraLarge).background(c.surfaceContainer).clickable(onClick = onOpen).padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AsyncImage(
            model = mark.closeUp.url,
            contentDescription = stringResource(R.string.open_close_up, mark.text),
            contentScale = ContentScale.Crop,
            modifier = Modifier.size(56.dp).clip(Corners.Medium).background(c.surfaceContainerHigh),
        )
        Column(Modifier.weight(1f)) {
            Text(mark.text, style = MaterialTheme.typography.bodyLarge)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                SymbolIcon(Symbol.PhotoCamera, null, size = 16.dp, tint = c.onSurfaceVariant)
                Text(capturedLabel, style = MaterialTheme.typography.bodySmall, color = c.onSurfaceVariant)
            }
        }
        Box { SymbolIcon(Symbol.ChevronRight, null, tint = c.onSurfaceVariant) }
    }
}
```

`GroupedList.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.runtime.key
import androidx.compose.ui.unit.dp
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon

class GroupScope internal constructor() {
    internal val rows = mutableListOf<Pair<Any, @Composable () -> Unit>>()
    fun row(key: Any, content: @Composable () -> Unit) { rows += key to content }
}

private val LocalRowShape = compositionLocalOf { RoundedCornerShape(4.dp) }

/** Android 16 Settings groups: separate surfaceContainer blocks 2 dp apart, 28 dp outer and 4 dp inner corners. */
@Composable
fun GroupedList(modifier: Modifier = Modifier, title: String? = null, content: GroupScope.() -> Unit) {
    val rows = GroupScope().apply(content).rows
    Column(modifier) {
        if (title != null) {
            Text(title, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(start = 16.dp, bottom = 8.dp))
        }
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            rows.forEachIndexed { i, (rowKey, row) ->
                val top = if (i == 0) 28.dp else 4.dp
                val bottom = if (i == rows.lastIndex) 28.dp else 4.dp
                key(rowKey) {
                    CompositionLocalProvider(LocalRowShape provides RoundedCornerShape(top, top, bottom, bottom)) { row() }
                }
            }
        }
    }
}

/** One row of a group: at least 72 dp, leading icon, bodyLarge title, bodySmall supporting text, trailing control. */
@Composable
fun GroupRow(
    title: String,
    modifier: Modifier = Modifier,
    supporting: String? = null,
    leading: Symbol? = null,
    trailing: @Composable (() -> Unit)? = null,
    enabled: Boolean = true,
    onClick: (() -> Unit)? = null,
) {
    val c = MaterialTheme.colorScheme
    val label = listOfNotNull(title, supporting).joinToString(", ")
    Row(
        modifier
            .fillMaxWidth()
            .heightIn(min = 72.dp)
            .clip(LocalRowShape.current)
            .background(c.surfaceContainer)
            .then(if (onClick != null && enabled) Modifier.clickable(onClick = onClick) else Modifier)
            .semantics(mergeDescendants = true) { contentDescription = label }
            .padding(horizontal = 16.dp, vertical = 12.dp)
            .alpha(if (enabled) 1f else 0.38f),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        if (leading != null) SymbolIcon(leading, null, tint = c.onSurfaceVariant)
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            if (supporting != null) Text(supporting, style = MaterialTheme.typography.bodySmall, color = c.onSurfaceVariant)
        }
        trailing?.invoke()
    }
}
```

- [ ] **Step 6: Run the tests, record and review**

Run: `./gradlew :core:designsystem:testDebugUnitTest`
Expected: PASS, 11 tests.

Run: `./gradlew :core:designsystem:recordRoborazziDebug` and compare `deal-components-*.png` with the console and "Giao dịch" section in `tmp/chat.html` and `tmp/detail.html`. Check: the current phase sits in a cookie shape, done phases are teal checks, the milestone is a pale peach cookie with a terracotta handshake, the condition scale has Như mới selected with a check, group rows have big outer and small inner corners, the dimmed COD row reads at 38 %. At font130 the money sentence wraps without clipping.

Run: `./gradlew :core:designsystem:verifyRoborazziDebug`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add core/designsystem
git commit -m "feat(designsystem): add the phase stepper, money note, milestone, tier chip, condition scale and grouped list

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16: Screen chrome components

Top bar, docked action bar, navigation bar, FAB menu, full-width sheet and dialog, and the hook the debug panel opens from.

**Files:**
- Create in `app2/core/designsystem/src/main/kotlin/vn/shopnexus/core/designsystem/component/`: `TopBar.kt`, `DockedActionBar.kt`, `NavigationBar.kt`, `FabMenu.kt`, `Sheet.kt`, `Dialog.kt`, `Debug.kt`
- Modify: `app2/core/designsystem/src/main/res/values/strings.xml`
- Test: `app2/core/designsystem/src/test/kotlin/vn/shopnexus/core/designsystem/ChromeComponentsTest.kt`

**Interfaces:**
- Consumes: Task 13 theme and icons.
- Produces:
  ```kotlin
  val LocalDebugTrigger: ProvidableCompositionLocal<(() -> Unit)?>      // null in release builds
  fun Modifier.debugTrigger(): Modifier                                 // long press opens the debug panel when one is provided
  @Composable fun ShopNexusTopBar(title: @Composable () -> Unit, onBack: () -> Unit, modifier: Modifier = Modifier,
                                  actions: @Composable RowScope.() -> Unit = {}, containerColor: Color = MaterialTheme.colorScheme.surface)
  @Composable fun DockedActionBar(modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit)
  data class NavItem(val label: String, val icon: Symbol, val badge: Int? = null)
  @Composable fun ShopNexusNavigationBar(items: List<NavItem>, selected: Int, onSelect: (Int) -> Unit, modifier: Modifier = Modifier)
  data class FabAction(val label: String, val icon: Symbol, val onClick: () -> Unit)
  @Composable fun FabMenu(label: String, actions: List<FabAction>, expanded: Boolean, onExpandedChange: (Boolean) -> Unit,
                          extended: Boolean, modifier: Modifier = Modifier)   // the open menu and its scrim cover the whole window
  @Composable fun FullWidthSheet(onDismiss: () -> Unit, title: String, modifier: Modifier = Modifier,
                                 sheetState: SheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                                 content: @Composable ColumnScope.() -> Unit)
  @Composable fun ShopNexusDialog(title: String, text: String, confirm: String, onConfirm: () -> Unit,
                                  dismiss: String, onDismiss: () -> Unit, icon: Symbol? = null)
  ```

- [ ] **Step 1: Add the strings**

```xml
    <string name="back">Quay lại</string>
    <string name="close">Đóng</string>
    <string name="nav_label">Điều hướng chính</string>
    <string name="unread_count">%1$d chưa đọc</string>
```

- [ ] **Step 2: Write the failing test**

`ChromeComponentsTest.kt`:

```kotlin
package vn.shopnexus.core.designsystem

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Text
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import vn.shopnexus.core.designsystem.component.DockedActionBar
import vn.shopnexus.core.designsystem.component.FabAction
import vn.shopnexus.core.designsystem.component.FabMenu
import vn.shopnexus.core.designsystem.component.LocalDebugTrigger
import vn.shopnexus.core.designsystem.component.NavItem
import vn.shopnexus.core.designsystem.component.ShopNexusNavigationBar
import vn.shopnexus.core.designsystem.component.ShopNexusTopBar
import vn.shopnexus.core.designsystem.component.debugTrigger
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.theme.ShopNexusTheme
import vn.shopnexus.core.testing.captureVariants

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w412dp-h915dp-xhdpi")
class ChromeComponentsTest {
    @get:Rule val compose = createComposeRule()
    private val tabs = listOf(
        NavItem("Khám phá", Symbol.Home), NavItem("Danh mục", Symbol.GridView),
        NavItem("Tin nhắn", Symbol.Chat, badge = 3), NavItem("Tôi", Symbol.Person),
    )

    @Test
    fun longPressOnATitleOpensTheDebugPanelOnlyWhenOneIsProvided() {
        var opened = 0
        compose.setContent {
            ShopNexusTheme {
                CompositionLocalProvider(LocalDebugTrigger provides { opened++ }) {
                    ShopNexusTopBar(title = { Text("Tuấn Kiệt", Modifier.debugTrigger()) }, onBack = {})
                }
            }
        }
        compose.onNodeWithText("Tuấn Kiệt").performTouchInput { longClick() }
        assertThat(opened).isEqualTo(1)
    }

    @Test
    fun fabMenuOpensAndRunsAnAction() {
        var expanded by mutableStateOf(false)
        var ran = ""
        compose.setContent {
            ShopNexusTheme {
                FabMenu("Đăng tin", listOf(FabAction("Chụp ảnh", Symbol.PhotoCamera) { ran = "camera" }), expanded, { expanded = it }, extended = true)
            }
        }
        compose.onNodeWithText("Đăng tin").performClick()
        compose.onNodeWithText("Chụp ảnh").performClick()
        assertThat(ran).isEqualTo("camera")
    }

    @Test
    fun navigationBarAnnouncesTheBadge() {
        compose.setContent { ShopNexusTheme { ShopNexusNavigationBar(tabs, selected = 0, onSelect = {}) } }
        compose.onNodeWithContentDescription("3 chưa đọc").assertExists()
    }

    @Test
    fun screenshots() = compose.captureVariants("chrome-components") {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            ShopNexusTopBar(title = { Text("Tin nhắn") }, onBack = {})
            DockedActionBar {
                FilledTonalButton(onClick = {}, Modifier.weight(1f).height(48.dp)) { Text("Nhắn tin") }
                Button(onClick = {}, Modifier.weight(1f).height(48.dp)) { Text("Trả giá") }
            }
            ShopNexusNavigationBar(tabs, selected = 0, onSelect = {})
            Box(Modifier.fillMaxWidth().height(80.dp), contentAlignment = Alignment.CenterEnd) {
                FabMenu("Đăng tin", emptyList(), expanded = false, onExpandedChange = {}, extended = true)
            }
        }
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `./gradlew :core:designsystem:testDebugUnitTest --tests "*ChromeComponentsTest*"`
Expected: FAIL, unresolved references.

- [ ] **Step 4: Write the chrome**

`Debug.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed

/** Provided by the debug build of `:app`; release builds leave it null. */
val LocalDebugTrigger = compositionLocalOf<(() -> Unit)?> { null }

/** A long press opens the debug panel. Put it on top-bar titles and on Home's location pill. */
@OptIn(ExperimentalFoundationApi::class)
fun Modifier.debugTrigger(): Modifier = composed {
    val trigger = LocalDebugTrigger.current
    if (trigger == null) this else combinedClickable(onClick = {}, onLongClick = trigger, onClickLabel = null)
}
```

A `combinedClickable` with an empty `onClick` would swallow taps on a clickable element; use `debugTrigger()` only on elements without their own click (titles), and on the location pill pass the pill's own click to a `combinedClickable` there instead (Task 19 shows it).

`TopBar.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.foundation.layout.RowScope
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ProvideTextStyle
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import vn.shopnexus.core.designsystem.R
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon

/** The 64 dp bar of pushed screens: back, a titleLarge title, up to two actions. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShopNexusTopBar(
    title: @Composable () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    actions: @Composable RowScope.() -> Unit = {},
    containerColor: Color = MaterialTheme.colorScheme.surface,
) {
    TopAppBar(
        title = { ProvideTextStyle(MaterialTheme.typography.titleLarge) { title() } },
        navigationIcon = {
            IconButton(onClick = onBack) { SymbolIcon(Symbol.ArrowBack, stringResource(R.string.back)) }
        },
        actions = actions,
        colors = TopAppBarDefaults.topAppBarColors(containerColor = containerColor, scrolledContainerColor = MaterialTheme.colorScheme.surfaceContainer),
        modifier = modifier,
    )
}
```

`DockedActionBar.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/** The main-task bar above the gesture area: surfaceContainer, 12 dp top padding, two 48 dp buttons 12 dp apart. */
@Composable
fun DockedActionBar(modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    Row(
        modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceContainer)
            .windowInsetsPadding(WindowInsets.navigationBars)
            .padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        content = content,
    )
}
```

`NavigationBar.kt`, on the 64 dp M3 Expressive short navigation bar:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ShortNavigationBar
import androidx.compose.material3.ShortNavigationBarItem
import androidx.compose.material3.ShortNavigationBarItemDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import vn.shopnexus.core.designsystem.R
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon

data class NavItem(val label: String, val icon: Symbol, val badge: Int? = null)

/** 64 dp, surfaceContainer, every label shown; the active one in secondary at 600 with a filled icon in a 56 × 32 dp pill. */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ShopNexusNavigationBar(items: List<NavItem>, selected: Int, onSelect: (Int) -> Unit, modifier: Modifier = Modifier) {
    val c = MaterialTheme.colorScheme
    ShortNavigationBar(modifier, containerColor = c.surfaceContainer) {
        items.forEachIndexed { i, item ->
            val on = i == selected
            ShortNavigationBarItem(
                selected = on,
                onClick = { onSelect(i) },
                icon = {
                    BadgedBox(badge = {
                        if (item.badge != null && item.badge > 0) {
                            val badgeLabel = stringResource(R.string.unread_count, item.badge)
                            Badge(Modifier.semantics { contentDescription = badgeLabel }) { Text(item.badge.toString()) }
                        }
                    }) { SymbolIcon(item.icon, contentDescription = null, filled = on) }
                },
                label = {
                    Text(
                        item.label,
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = if (on) FontWeight.SemiBold else FontWeight.Medium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
                colors = ShortNavigationBarItemDefaults.colors(
                    selectedIconColor = c.onSecondaryContainer,
                    selectedTextColorTopIconPosition = c.secondary,
                    selectedIndicatorColor = c.secondaryContainer,
                    unselectedIconColor = c.onSurfaceVariant,
                    unselectedTextColor = c.onSurfaceVariant,
                ),
            )
        }
    }
}
```

`FabMenu.kt`. The open menu and its scrim go into a full-window popup, so the scrim also covers the navigation bar, which `:app` draws outside Home:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FloatingActionButtonMenu
import androidx.compose.material3.FloatingActionButtonMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.ToggleFloatingActionButton
import androidx.compose.material3.ToggleFloatingActionButtonDefaults.animateIcon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.traversalIndex
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import kotlin.math.roundToInt
import vn.shopnexus.core.designsystem.R
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.vector

data class FabAction(val label: String, val icon: Symbol, val onClick: () -> Unit)

private object WindowTopStart : PopupPositionProvider {
    override fun calculatePosition(anchorBounds: IntRect, windowSize: IntSize, layoutDirection: LayoutDirection, popupContentSize: IntSize) =
        IntOffset.Zero
}

/**
 * Closed: the extended FAB in primaryContainer, collapsing to its icon while the feed scrolls down
 * ([extended] false). Open: a surface scrim at 80 % over the whole window and the M3 Expressive FAB
 * menu in the FAB's place, its plus turned into a close mark; items rise from the FAB.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun FabMenu(
    label: String,
    actions: List<FabAction>,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    extended: Boolean,
    modifier: Modifier = Modifier,
) {
    var corner by remember { mutableStateOf(IntOffset.Zero) }
    ExtendedFloatingActionButton(
        onClick = { onExpandedChange(true) },
        expanded = extended,
        icon = { Icon(Symbol.Add.vector(), contentDescription = null) },
        text = { Text(label) },
        containerColor = MaterialTheme.colorScheme.primaryContainer,
        contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
        modifier = modifier
            .alpha(if (expanded) 0f else 1f)
            .onGloballyPositioned { val b = it.boundsInWindow(); corner = IntOffset(b.right.roundToInt(), b.bottom.roundToInt()) },
    )
    if (!expanded) return
    val closeLabel = stringResource(R.string.close)
    Popup(popupPositionProvider = WindowTopStart, onDismissRequest = { onExpandedChange(false) }, properties = PopupProperties(focusable = true)) {
        var shown by remember { mutableStateOf(false) }
        LaunchedEffect(Unit) { shown = true }
        Box(
            Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.8f))
                .clickable(remember { MutableInteractionSource() }, indication = null) { onExpandedChange(false) },
        ) {
            FloatingActionButtonMenu(
                expanded = shown,
                modifier = Modifier.layout { measurable, constraints ->
                    val menu = measurable.measure(constraints.copy(minWidth = 0, minHeight = 0))
                    layout(constraints.maxWidth, constraints.maxHeight) { menu.place(corner.x - menu.width, corner.y - menu.height) }
                },
                button = {
                    ToggleFloatingActionButton(
                        checked = shown,
                        onCheckedChange = { onExpandedChange(false) },
                        modifier = Modifier.semantics { traversalIndex = -1f; contentDescription = closeLabel },
                    ) {
                        Icon(
                            if (checkedProgress > 0.5f) Symbol.Close.vector() else Symbol.Add.vector(),
                            contentDescription = null,
                            modifier = Modifier.animateIcon({ checkedProgress }),
                        )
                    }
                },
            ) {
                actions.forEach { action ->
                    FloatingActionButtonMenuItem(
                        onClick = { onExpandedChange(false); action.onClick() },
                        icon = { Icon(action.icon.vector(), contentDescription = null) },
                        text = { Text(action.label) },
                    )
                }
            }
        }
    }
}
```

`Sheet.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetState
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import vn.shopnexus.core.designsystem.R
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon

/** A modal sheet across the whole width: surfaceContainerLow, 28 dp top corners, black scrim at 32 %, a title row with close. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FullWidthSheet(
    onDismiss: () -> Unit,
    title: String,
    modifier: Modifier = Modifier,
    sheetState: SheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    content: @Composable ColumnScope.() -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        sheetMaxWidth = Dp.Infinity,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
        containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
        scrimColor = Color.Black.copy(alpha = 0.32f),
        modifier = modifier,
    ) {
        Column(Modifier.padding(horizontal = 24.dp).navigationBarsPadding().padding(bottom = 16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title, style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f).semantics { heading() })
                IconButton(onClick = onDismiss) { SymbolIcon(Symbol.Close, stringResource(R.string.close)) }
            }
            content()
        }
    }
}
```

`Dialog.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon

/** The M3 alert layout: optional icon, title, text, two text buttons. */
@Composable
fun ShopNexusDialog(
    title: String,
    text: String,
    confirm: String,
    onConfirm: () -> Unit,
    dismiss: String,
    onDismiss: () -> Unit,
    icon: Symbol? = null,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = icon?.let { { SymbolIcon(it, null) } },
        title = { Text(title) },
        text = { Text(text) },
        confirmButton = { TextButton(onClick = onConfirm) { Text(confirm) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(dismiss) } },
    )
}
```

- [ ] **Step 5: Write the previews**

Every component has an Android Studio preview in light, dark and at font scale 1.3. `app2/core/designsystem/src/main/kotlin/vn/shopnexus/core/designsystem/component/Previews.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.tooling.preview.PreviewLightDark
import androidx.compose.ui.unit.dp
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.theme.ShopNexusTheme
import vn.shopnexus.core.designsystem.theme.ThemeMode
import vn.shopnexus.core.domain.offerRange
import vn.shopnexus.core.model.Condition
import vn.shopnexus.core.model.DeclaredMark
import vn.shopnexus.core.model.ListingId
import vn.shopnexus.core.model.ListingSummary
import vn.shopnexus.core.model.MoneyKey
import vn.shopnexus.core.model.Photo
import vn.shopnexus.core.model.PhotoSource
import vn.shopnexus.core.model.PriceDirection
import vn.shopnexus.core.model.PriceInsight
import vn.shopnexus.core.model.Tier
import vn.shopnexus.core.model.Vnd

private val sample = ListingSummary(
    ListingId("p-iphone13"), "", Vnd(10_900_000), "iPhone 13 Pro 128GB, Xanh Sierra, pin 88%",
    Condition.LIKE_NEW, 1.6, PriceInsight(PriceDirection.CHEAPER, 13),
)

@Composable
private fun Frame(content: @Composable () -> Unit) = ShopNexusTheme(ThemeMode.SYSTEM) {
    Surface(color = MaterialTheme.colorScheme.surface) { Column(Modifier.padding(vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) { content() } }
}

@PreviewLightDark
@Preview(name = "font 1.3", fontScale = 1.3f)
@Composable
private fun ListingPreview() = Frame {
    SectionHeader("Gần bạn", onSeeAll = {})
    ListingRail(listOf(sample, sample.copy(id = ListingId("b"), saved = true)), onOpen = {}, onToggleSave = {})
    Figure(Vnd(10_600_000), Modifier.padding(horizontal = 16.dp))
    AmountStepper(Vnd(10_500_000), offerRange(Vnd(10_900_000), Vnd(10_600_000)), onStep = {}, onType = {}, Modifier.padding(horizontal = 16.dp))
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@PreviewLightDark
@Preview(name = "font 1.3", fontScale = 1.3f)
@Composable
private fun DealPreview() = Frame {
    PhaseStepper(current = 1, set = PhaseSet.MEET, modifier = Modifier.padding(horizontal = 16.dp))
    MoneyNote(MoneyKey.MEET, Modifier.padding(horizontal = 16.dp))
    Milestone(MaterialShapes.Cookie9Sided, MilestoneTone.DEAL, Symbol.Handshake, "Chốt 10,6 tr", "Bắt tay rồi! Giờ hẹn gặp để xem máy nhé.", animate = false)
    TierChip(Tier.TOP, Modifier.padding(horizontal = 16.dp))
    ConditionScale(Condition.LIKE_NEW, Modifier.padding(horizontal = 16.dp))
    DeclaredMarkRow(DeclaredMark("2 vết xước nhỏ ở viền", Photo("", PhotoSource.APP)), "Ảnh cận chụp trong app · 12/10", onOpen = {}, Modifier.padding(horizontal = 16.dp))
    GroupedList(Modifier.padding(horizontal = 16.dp), title = "Giao dịch") {
        row("meet") { GroupRow("Gặp mặt", supporting = "Bình Thạnh · sau 18:00", leading = Symbol.Handshake) }
        row("cod") { GroupRow("COD, xem hàng trước", supporting = "Món trên 5 triệu chỉ giao dịch gặp mặt.", leading = Symbol.Block, enabled = false) }
    }
}

@PreviewLightDark
@Preview(name = "font 1.3", fontScale = 1.3f)
@Composable
private fun ChromePreview() = Frame {
    ShopNexusTopBar(title = { Text("Tuấn Kiệt") }, onBack = {})
    DockedActionBar {
        FilledTonalButton(onClick = {}, Modifier.weight(1f).height(48.dp)) { Text("Nhắn tin") }
        Button(onClick = {}, Modifier.weight(1f).height(48.dp)) { Text("Trả giá") }
    }
    ShopNexusNavigationBar(
        listOf(NavItem("Khám phá", Symbol.Home), NavItem("Danh mục", Symbol.GridView), NavItem("Tin nhắn", Symbol.Chat, 3), NavItem("Tôi", Symbol.Person)),
        selected = 0, onSelect = {},
    )
    ShopNexusLoading()
}
```

Run: `./gradlew :core:designsystem:compileDebugKotlin`
Expected: BUILD SUCCESSFUL. Open `Previews.kt` in Android Studio once and check the three previews render in each of their variants.

- [ ] **Step 6: Run the tests, record and review**

Run: `./gradlew :core:designsystem:testDebugUnitTest`
Expected: PASS, 15 tests.

Run: `./gradlew :core:designsystem:recordRoborazziDebug` and compare `chrome-components-*.png` with the bars in `tmp/detail.html` and `tmp/home.html`: the 64 dp nav bar shows all four labels, Khám phá filled in a pale 56 × 32 dp pill with its label in teal at 600, an error-red badge "3" on Tin nhắn; the docked bar has a tonal and a filled 48 dp button; the extended FAB is teal-container with a plus. At font130 nav labels stay on one line and ellipsize rather than wrap. The open FAB menu lives in a popup, which `captureRoboImage` on the root does not draw; `fabMenuOpensAndRunsAnAction` covers it.

Run: `./gradlew :core:designsystem:verifyRoborazziDebug`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add core/designsystem
git commit -m "feat(designsystem): add the top bar, docked action bar, navigation bar, FAB menu, sheet and dialog

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```


---

### Task 17: Routes and the placeholder feature

`:core:navigation` names every screen as a serializable key and defines how a feature adds its screens. `:feature:placeholder` stands in for the screens of later stages, so no control in the slice leads nowhere. The first feature module also brings the feature convention plugin and the build check that keeps colours inside the theme.

**Files:**
- Create: `app2/build-logic/convention/src/main/kotlin/AndroidFeatureConventionPlugin.kt`
- Create: `app2/build-logic/convention/src/main/kotlin/CheckNoRawColorsTask.kt`
- Modify: `app2/build-logic/convention/build.gradle.kts` (register `shopnexus.android.feature`)
- Modify: `app2/build-logic/convention/src/main/kotlin/AndroidLibraryComposeConventionPlugin.kt` (register the check outside `:core:designsystem`)
- Modify: `app2/settings.gradle.kts` (add `include(":core:navigation", ":feature:placeholder")`)
- Create: `app2/core/navigation/build.gradle.kts`
- Create in `app2/core/navigation/src/main/kotlin/vn/shopnexus/core/navigation/`: `Routes.kt`, `Navigator.kt`, `DeepLinks.kt`
- Test: `app2/core/navigation/src/test/kotlin/vn/shopnexus/core/navigation/DeepLinksTest.kt`
- Create: `app2/feature/placeholder/build.gradle.kts`
- Create in `app2/feature/placeholder/src/main/kotlin/vn/shopnexus/feature/placeholder/`: `PlaceholderScreen.kt`, `PlaceholderInstaller.kt`
- Create: `app2/feature/placeholder/src/main/res/values/strings.xml`
- Create: `app2/feature/placeholder/src/test/resources/robolectric.properties` (`sdk=36`)
- Test: `app2/feature/placeholder/src/test/kotlin/vn/shopnexus/feature/placeholder/PlaceholderScreenTest.kt`

**Interfaces:**
- Consumes: the design system (Tasks 13–16).
- Produces:
  ```kotlin
  @Serializable data object HomeRoute : NavKey
  @Serializable data object CategoriesRoute : NavKey
  @Serializable data object InboxRoute : NavKey
  @Serializable data object MeRoute : NavKey
  @Serializable data class ListingRoute(val id: String) : NavKey
  @Serializable data class ChatRoute(val dealId: String) : NavKey
  @Serializable data class PlaceholderRoute(val stage: Int, val title: String) : NavKey
  val TopLevelRoutes: List<NavKey>          // Home, Categories, Inbox, Me, in tab order
  interface Navigator { fun push(route: NavKey); fun back(); fun selectTab(tab: NavKey) }
  interface EntryInstaller { fun install(scope: EntryProviderScope<NavKey>, navigator: Navigator) }
  object DeepLinks { fun parse(uri: String): NavKey? }   // shopnexus://listing/{id}, shopnexus://deal/{id}
  // plugin ids
  shopnexus.android.feature    // Compose + Hilt + ViewModel + Navigation 3 + :core:* ; checkNoRawColors
  ```

- [ ] **Step 1: Write the raw-colour check**

`app2/build-logic/convention/src/main/kotlin/CheckNoRawColorsTask.kt`:

```kotlin
import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.Project
import org.gradle.api.file.ConfigurableFileCollection
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.tasks.CacheableTask
import org.gradle.api.tasks.InputFiles
import org.gradle.api.tasks.OutputFile
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.SkipWhenEmpty
import org.gradle.api.tasks.TaskAction

/**
 * Colours come from the theme. Outside `:core:designsystem`, `Color(0x…)` and named colours such as
 * `Color.Red` fail the build; `Color.Black`, `White`, `Transparent` and `Unspecified` stay allowed for photo scrims.
 */
@CacheableTask
abstract class CheckNoRawColorsTask : DefaultTask() {
    @get:InputFiles
    @get:SkipWhenEmpty
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val sources: ConfigurableFileCollection

    @get:OutputFile
    abstract val report: RegularFileProperty

    @TaskAction
    fun scan() {
        val raw = Regex("""Color\(\s*0x|Color\.(Red|Green|Blue|Yellow|Cyan|Magenta|Gray|DarkGray|LightGray)\b""")
        val hits = sources.files.sortedBy { it.path }.flatMap { file ->
            file.readLines().mapIndexedNotNull { i, line ->
                if (raw.containsMatchIn(line)) "${file.path}:${i + 1}: ${line.trim()}" else null
            }
        }
        report.get().asFile.writeText(hits.joinToString("\n"))
        if (hits.isNotEmpty()) throw GradleException("Colours must come from the theme:\n" + hits.joinToString("\n"))
    }
}

internal fun Project.registerCheckNoRawColors() {
    val task = tasks.register("checkNoRawColors", CheckNoRawColorsTask::class.java) {
        sources.from(fileTree("src/main") { include("**/*.kt") })
        report.set(layout.buildDirectory.file("reports/checkNoRawColors.txt"))
    }
    tasks.named("check") { dependsOn(task) }
}
```

In `AndroidLibraryComposeConventionPlugin.apply`, after the `dependencies { … }` block, add:

```kotlin
        if (path != ":core:designsystem") registerCheckNoRawColors()
```

- [ ] **Step 2: Write the feature convention plugin**

`app2/build-logic/convention/src/main/kotlin/AndroidFeatureConventionPlugin.kt`:

```kotlin
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.dependencies
import org.gradle.kotlin.dsl.project

/** A feature: Compose, Hilt, ViewModels and Navigation 3 on top of the core modules. Features never depend on each other. */
class AndroidFeatureConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("shopnexus.android.library.compose")
        pluginManager.apply("shopnexus.hilt")
        dependencies {
            add("implementation", project(":core:designsystem"))
            add("implementation", project(":core:navigation"))
            add("implementation", project(":core:data"))
            add("implementation", libs.library("androidx-lifecycle-runtime-compose"))
            add("implementation", libs.library("androidx-lifecycle-viewmodel-compose"))
            add("implementation", libs.library("androidx-hilt-lifecycle-viewmodel-compose"))
            add("implementation", libs.library("androidx-navigation3-runtime"))
            add("testImplementation", project(":core:testing"))
        }
    }
}
```

`registerCheckNoRawColors()` runs through the Compose library plugin it applies. Register the plugin in `build-logic/convention/build.gradle.kts`:

```kotlin
        register("androidFeature") {
            id = "shopnexus.android.feature"
            implementationClass = "AndroidFeatureConventionPlugin"
        }
```

- [ ] **Step 3: Write the failing deep-link test**

Add `include(":core:navigation", ":feature:placeholder")` to `app2/settings.gradle.kts`.

`app2/core/navigation/build.gradle.kts`:

```kotlin
plugins {
    id("shopnexus.android.library")
}

android {
    namespace = "vn.shopnexus.core.navigation"
}

dependencies {
    api(libs.androidx.navigation3.runtime)
}
```

`DeepLinksTest.kt`:

```kotlin
package vn.shopnexus.core.navigation

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class DeepLinksTest {
    @Test
    fun listingAndDealLinksOpenTheirScreens() {
        assertThat(DeepLinks.parse("shopnexus://listing/p-iphone13")).isEqualTo(ListingRoute("p-iphone13"))
        assertThat(DeepLinks.parse("shopnexus://deal/d-kiet")).isEqualTo(ChatRoute("d-kiet"))
        assertThat(DeepLinks.parse("SHOPNEXUS://deal/d-kiet")).isEqualTo(ChatRoute("d-kiet"))
        assertThat(DeepLinks.parse("shopnexus://listing/p-iphone13/")).isEqualTo(ListingRoute("p-iphone13"))
    }

    @Test
    fun anythingElseIsIgnored() {
        listOf(
            "shopnexus://listing/", "shopnexus://listing", "shopnexus://seller/u-kiet", "https://listing/p-1",
            "shopnexus://listing/a/b", "shopnexus://listing/%2e%2e", "shopnexus://deal/" + "x".repeat(65), "not a uri ::",
        ).forEach { assertThat(DeepLinks.parse(it)).isNull() }
    }
}
```

Run: `./gradlew :core:navigation:testDebugUnitTest`
Expected: FAIL, `Unresolved reference 'DeepLinks'`.

- [ ] **Step 4: Write the routes, the navigator contract and the parser**

`Routes.kt`:

```kotlin
package vn.shopnexus.core.navigation

import androidx.navigation3.runtime.NavKey
import kotlinx.serialization.Serializable

@Serializable data object HomeRoute : NavKey
@Serializable data object CategoriesRoute : NavKey
@Serializable data object InboxRoute : NavKey
@Serializable data object MeRoute : NavKey

@Serializable data class ListingRoute(val id: String) : NavKey
@Serializable data class ChatRoute(val dealId: String) : NavKey

/** A screen a later stage builds; [stage] is its stage in the spec. */
@Serializable data class PlaceholderRoute(val stage: Int, val title: String) : NavKey

/** The four tabs, in the order the navigation bar shows them. */
val TopLevelRoutes: List<NavKey> = listOf(HomeRoute, CategoriesRoute, InboxRoute, MeRoute)
```

`Navigator.kt`:

```kotlin
package vn.shopnexus.core.navigation

import androidx.navigation3.runtime.EntryProviderScope
import androidx.navigation3.runtime.NavKey

/** How screens move. `:app` implements it over one back stack per tab. */
interface Navigator {
    /** Opens [route] on top of the current tab. */
    fun push(route: NavKey)

    /** Closes the top screen; at a tab's root, goes back to Khám phá. */
    fun back()

    /** Switches tab, keeping each tab's stack; selecting the current tab returns to its root. */
    fun selectTab(tab: NavKey)
}

/** Each feature adds its screens through one installer, bound into a Hilt set. */
interface EntryInstaller {
    fun install(scope: EntryProviderScope<NavKey>, navigator: Navigator)
}
```

`DeepLinks.kt`:

```kotlin
package vn.shopnexus.core.navigation

import androidx.navigation3.runtime.NavKey
import java.net.URI

/** `shopnexus://listing/{id}` and `shopnexus://deal/{id}`; anything else is ignored. */
object DeepLinks {
    private val ID = Regex("[A-Za-z0-9_-]{1,64}")

    fun parse(uri: String): NavKey? {
        val parsed = runCatching { URI(uri) }.getOrNull() ?: return null
        if (!parsed.scheme.equals("shopnexus", ignoreCase = true)) return null
        val segments = parsed.rawPath.orEmpty().split('/').filter { it.isNotEmpty() }
        val id = segments.singleOrNull()?.takeIf { ID.matches(it) } ?: return null
        return when (parsed.host) {
            "listing" -> ListingRoute(id)
            "deal" -> ChatRoute(id)
            else -> null
        }
    }
}
```

Run: `./gradlew :core:navigation:testDebugUnitTest`
Expected: PASS, 2 tests.

- [ ] **Step 5: Write the failing placeholder test**

`app2/feature/placeholder/build.gradle.kts`:

```kotlin
plugins {
    id("shopnexus.android.feature")
}

android {
    namespace = "vn.shopnexus.feature.placeholder"
}
```

`PlaceholderScreenTest.kt`:

```kotlin
package vn.shopnexus.feature.placeholder

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import vn.shopnexus.core.designsystem.theme.ShopNexusTheme
import vn.shopnexus.core.testing.captureVariants

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w412dp-h915dp-xhdpi")
class PlaceholderScreenTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun aPushedPlaceholderNamesItsStageAndGoesBack() {
        var back = 0
        compose.setContent { ShopNexusTheme { PlaceholderScreen("Thông báo", stage = 2, onBack = { back++ }) } }
        compose.onNodeWithText("Màn này làm ở giai đoạn 2: Khám phá.").assertExists()
        compose.onNodeWithContentDescription("Quay lại").performClick()
        assertThat(back).isEqualTo(1)
    }

    @Test
    fun aTabPlaceholderHasNoBack() {
        compose.setContent { ShopNexusTheme { PlaceholderScreen("Tin nhắn", stage = 3, onBack = null) } }
        compose.onNodeWithText("Tin nhắn").assertExists()
        compose.onNodeWithContentDescription("Quay lại").assertDoesNotExist()
    }

    @Test
    fun screenshots() = compose.captureVariants("placeholder") { PlaceholderScreen("Người bán", stage = 2, onBack = {}) }
}
```

Run: `./gradlew :feature:placeholder:testDebugUnitTest`
Expected: FAIL, `Unresolved reference 'PlaceholderScreen'`.

- [ ] **Step 6: Write the placeholder screen and its installer**

`app2/feature/placeholder/src/main/res/values/strings.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="placeholder_title">Giai đoạn %1$d</string>
    <string name="placeholder_line">Màn này làm ở giai đoạn %1$d: %2$s.</string>
    <string name="stage_2">Khám phá</string>
    <string name="stage_3">Giao dịch</string>
    <string name="stage_4">Bán</string>
    <string name="stage_5">Tài khoản và tin cậy</string>
    <string name="tab_categories">Danh mục</string>
    <string name="tab_inbox">Tin nhắn</string>
    <string name="tab_me">Tôi</string>
</resources>
```

`PlaceholderScreen.kt`:

```kotlin
package vn.shopnexus.feature.placeholder

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import vn.shopnexus.core.designsystem.component.Milestone
import vn.shopnexus.core.designsystem.component.MilestoneTone
import vn.shopnexus.core.designsystem.component.ShopNexusTopBar
import vn.shopnexus.core.designsystem.component.debugTrigger
import vn.shopnexus.core.designsystem.icon.Symbol

@Composable
private fun stageName(stage: Int): String = stringResource(
    when (stage) {
        2 -> R.string.stage_2
        3 -> R.string.stage_3
        4 -> R.string.stage_4
        else -> R.string.stage_5
    },
)

/** Stands in for a screen of a later stage. Pushed, it has a back arrow; as a tab, its title sits in headlineSmall. */
@Composable
fun PlaceholderScreen(title: String, stage: Int, onBack: (() -> Unit)?, modifier: Modifier = Modifier) {
    Scaffold(
        modifier = modifier,
        topBar = {
            if (onBack != null) {
                ShopNexusTopBar(title = { Text(title, Modifier.debugTrigger()) }, onBack = onBack)
            } else {
                Text(
                    title,
                    style = MaterialTheme.typography.headlineSmall,
                    modifier = Modifier.statusBarsPadding().fillMaxWidth().height(64.dp).padding(horizontal = 16.dp)
                        .wrapContentHeight(Alignment.CenterVertically).debugTrigger(),
                )
            }
        },
    ) { padding ->
        Column(
            Modifier.padding(padding).fillMaxSize().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Milestone(
                shape = MaterialShapes.Arch,
                tone = MilestoneTone.CALM,
                icon = Symbol.Schedule,
                title = stringResource(R.string.placeholder_title, stage),
                line = stringResource(R.string.placeholder_line, stage, stageName(stage)),
                animate = false,
            )
        }
    }
}
```

`PlaceholderInstaller.kt`:

```kotlin
package vn.shopnexus.feature.placeholder

import androidx.compose.ui.res.stringResource
import androidx.navigation3.runtime.EntryProviderScope
import androidx.navigation3.runtime.NavKey
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dagger.multibindings.IntoSet
import javax.inject.Inject
import vn.shopnexus.core.navigation.CategoriesRoute
import vn.shopnexus.core.navigation.EntryInstaller
import vn.shopnexus.core.navigation.InboxRoute
import vn.shopnexus.core.navigation.MeRoute
import vn.shopnexus.core.navigation.Navigator
import vn.shopnexus.core.navigation.PlaceholderRoute

/** The three tabs stage 1 does not build, and every pushed screen a later stage builds. */
class PlaceholderInstaller @Inject constructor() : EntryInstaller {
    override fun install(scope: EntryProviderScope<NavKey>, navigator: Navigator) = with(scope) {
        entry<PlaceholderRoute> { key -> PlaceholderScreen(key.title, key.stage, onBack = navigator::back) }
        entry<CategoriesRoute> { PlaceholderScreen(stringResource(R.string.tab_categories), stage = 2, onBack = null) }
        entry<InboxRoute> { PlaceholderScreen(stringResource(R.string.tab_inbox), stage = 3, onBack = null) }
        entry<MeRoute> { PlaceholderScreen(stringResource(R.string.tab_me), stage = 5, onBack = null) }
    }
}

@Module
@InstallIn(SingletonComponent::class)
abstract class PlaceholderModule {
    @Binds @IntoSet abstract fun installer(impl: PlaceholderInstaller): EntryInstaller
}
```

- [ ] **Step 7: Run the tests and record the screenshots**

Run: `./gradlew :feature:placeholder:testDebugUnitTest`
Expected: PASS, 3 tests.

Run: `./gradlew :feature:placeholder:recordRoborazziDebug` and look at `placeholder-*.png`: a back arrow and "Người bán" in the bar, a neutral arch shape with a clock, "Giai đoạn 2", and the line naming Khám phá.

- [ ] **Step 8: Prove the raw-colour check fails on a raw colour**

Temporarily add this line at the end of `PlaceholderScreen.kt`:

```kotlin
private val probe = androidx.compose.ui.graphics.Color(0xFF00FF00)
```

Run: `./gradlew :feature:placeholder:checkNoRawColors`
Expected: FAIL with `Colours must come from the theme:` and the file and line of the probe.

Delete the probe line and run it again. Expected: PASS. Then run `./gradlew :core:designsystem:tasks --all | grep checkNoRawColors`; expected: no output, since the design system is exempt.

- [ ] **Step 9: Commit**

```bash
git add build-logic settings.gradle.kts core/navigation feature/placeholder
git commit -m "feat(navigation): add routes, deep links, the placeholder feature and the raw-colour check

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 18: The app shell

`:app` holds the activity, one back stack per tab, the navigation bar, the theme settings and the hook for the debug panel. It follows the Navigation 3 "multiple back stacks" recipe: every tab keeps its own `NavBackStack` and its own entry decorators, so a tab keeps its screens and ViewModels while another is in front.

**Files:**
- Create: `app2/build-logic/convention/src/main/kotlin/AndroidApplicationConventionPlugin.kt`
- Modify: `app2/build-logic/convention/build.gradle.kts` (register `shopnexus.android.application`)
- Modify: `app2/settings.gradle.kts` (add `include(":app")`)
- Create: `app2/app/build.gradle.kts`, `app2/app/src/main/AndroidManifest.xml`
- Create: `app2/app/src/main/res/values/themes.xml`, `app2/app/src/main/res/values-night/themes.xml`, `app2/app/src/main/res/values/strings.xml`
- Create: `app2/app/src/main/res/drawable/ic_launcher_foreground.xml`, `app2/app/src/main/res/mipmap-anydpi/ic_launcher.xml`
- Create in `app2/app/src/main/kotlin/vn/shopnexus/app2/`: `ShopNexusApplication.kt`, `MainActivity.kt`, `AppNavigation.kt`, `ThemeSettings.kt`
- Create: `app2/app/src/debug/kotlin/vn/shopnexus/app2/DebugHost.kt`, `app2/app/src/release/kotlin/vn/shopnexus/app2/DebugHost.kt`
- Create: `app2/app/src/test/resources/robolectric.properties` (`sdk=36`)
- Test: `app2/app/src/test/kotlin/vn/shopnexus/app2/AppNavigatorTest.kt`
- Test: `app2/app/src/test/kotlin/vn/shopnexus/app2/ThemeSettingsTest.kt`

**Interfaces:**
- Consumes: `Navigator`, `EntryInstaller`, routes, `DeepLinks` (Task 17); `ShopNexusTheme`, `ThemeMode`, `ShopNexusNavigationBar`, `NavItem` (Tasks 13, 16).
- Produces:
  ```kotlin
  class NavigationState(val startRoute: NavKey, topLevelRoute: MutableState<NavKey>, val backStacks: Map<NavKey, NavBackStack<NavKey>>) {
      var topLevelRoute: NavKey
      val currentStack: NavBackStack<NavKey>
      val atRoot: Boolean
      @Composable fun toDecoratedEntries(entryProvider: (NavKey) -> NavEntry<NavKey>): List<NavEntry<NavKey>>
  }
  @Composable fun rememberNavigationState(startRoute: NavKey, topLevelRoutes: List<NavKey>): NavigationState
  class AppNavigator(val state: NavigationState) : Navigator { fun open(route: NavKey) }   // open = deep link onto Khám phá
  @Composable fun ShopNexusApp(installers: Set<EntryInstaller>, deepLink: NavKey?, onDeepLinkHandled: () -> Unit)
  class ThemeSettings(store: DataStore<Preferences>) { val mode: Flow<ThemeMode>; val dynamicColor: Flow<Boolean>
      suspend fun setMode(mode: ThemeMode); suspend fun setDynamicColor(on: Boolean) }
  @Composable fun DebugHost(content: @Composable () -> Unit)   // debug: provides LocalDebugTrigger; release: passes through
  ```

- [ ] **Step 1: Write the application convention plugin**

`app2/build-logic/convention/src/main/kotlin/AndroidApplicationConventionPlugin.kt`:

```kotlin
import com.android.build.api.dsl.ApplicationExtension
import org.gradle.api.JavaVersion
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.dependencies

class AndroidApplicationConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("com.android.application")
        pluginManager.apply("org.jetbrains.kotlin.plugin.compose")
        pluginManager.apply("org.jetbrains.kotlin.plugin.serialization")
        pluginManager.apply("io.github.takahirom.roborazzi")
        pluginManager.apply("shopnexus.hilt")
        extensions.configure<ApplicationExtension> {
            compileSdk = 36
            defaultConfig {
                minSdk = 31
                targetSdk = 36
            }
            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_21
                targetCompatibility = JavaVersion.VERSION_21
            }
            buildFeatures { compose = true }
            testOptions { unitTests { isIncludeAndroidResources = true } }
        }
        dependencies {
            val bom = libs.library("androidx-compose-bom")
            add("implementation", platform(bom))
            add("testImplementation", platform(bom))
            add("implementation", libs.library("androidx-compose-ui"))
            add("implementation", libs.library("androidx-compose-foundation"))
            add("implementation", libs.library("androidx-compose-material3"))
            add("debugImplementation", libs.library("androidx-compose-ui-tooling"))
            add("debugImplementation", libs.library("androidx-compose-ui-test-manifest"))
            add("testImplementation", libs.library("junit"))
            add("testImplementation", libs.library("truth"))
            add("testImplementation", libs.library("robolectric"))
        }
        registerCheckNoRawColors()
    }
}
```

Register it:

```kotlin
        register("androidApplication") {
            id = "shopnexus.android.application"
            implementationClass = "AndroidApplicationConventionPlugin"
        }
```

- [ ] **Step 2: Create the module**

Add `include(":app")` to `app2/settings.gradle.kts`.

`app2/app/build.gradle.kts`:

```kotlin
plugins {
    id("shopnexus.android.application")
}

android {
    namespace = "vn.shopnexus.app2"
    defaultConfig {
        applicationId = "vn.shopnexus.app2"
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
}

dependencies {
    implementation(project(":core:designsystem"))
    implementation(project(":core:navigation"))
    implementation(project(":core:data"))
    implementation(project(":feature:placeholder"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.navigation3)
    implementation(libs.androidx.navigation3.runtime)
    implementation(libs.androidx.navigation3.ui)
    implementation(libs.androidx.hilt.lifecycle.viewmodel.compose)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.coil.compose)
    implementation(libs.kotlinx.coroutines.android)
    testImplementation(project(":core:testing"))
    testImplementation(libs.hilt.android.testing)
    kspTest(libs.hilt.compiler)
}
```

Tasks 19 and 21 add `:feature:discover` and `:feature:deal` here.

`app2/app/src/main/AndroidManifest.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-permission android:name="android.permission.INTERNET" />

    <application
        android:name=".ShopNexusApplication"
        android:icon="@mipmap/ic_launcher"
        android:label="@string/app_name"
        android:supportsRtl="true"
        android:theme="@style/Theme.ShopNexus">
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:windowSoftInputMode="adjustResize">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="shopnexus" android:host="listing" />
                <data android:scheme="shopnexus" android:host="deal" />
            </intent-filter>
        </activity>
    </application>
</manifest>
```

`res/values/strings.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">ShopNexus</string>
    <string name="tab_home">Khám phá</string>
    <string name="tab_categories">Danh mục</string>
    <string name="tab_inbox">Tin nhắn</string>
    <string name="tab_me">Tôi</string>
</resources>
```

`res/values/themes.xml` (the window colour before Compose draws; `surface` of each scheme):

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="Theme.ShopNexus" parent="android:Theme.Material.Light.NoActionBar">
        <item name="android:windowBackground">#F7FAF8</item>
        <item name="android:statusBarColor">@android:color/transparent</item>
        <item name="android:navigationBarColor">@android:color/transparent</item>
    </style>
</resources>
```

`res/values-night/themes.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="Theme.ShopNexus" parent="android:Theme.Material.NoActionBar">
        <item name="android:windowBackground">#101413</item>
        <item name="android:statusBarColor">@android:color/transparent</item>
        <item name="android:navigationBarColor">@android:color/transparent</item>
    </style>
</resources>
```

`res/drawable/ic_launcher_foreground.xml` is the Material Symbols storefront in white, at half the 108 dp adaptive canvas. Write it from the path already in `Symbols.kt`:

```bash
cd /home/beanbocchi/shopnexus/app2
python3 - <<'PY'
import pathlib, re
kt = pathlib.Path("core/designsystem/src/main/kotlin/vn/shopnexus/core/designsystem/icon/Symbols.kt").read_text()
path = re.search(r'"storefront" to "([^"]+)"', kt).group(1)
out = pathlib.Path("app/src/main/res/drawable/ic_launcher_foreground.xml")
out.parent.mkdir(parents=True, exist_ok=True)
# The symbol's viewBox is 0 -960 960 960: scaling by 0.5 around the centre and moving down 480 centres it.
out.write_text(f"""<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="960" android:viewportHeight="960">
    <group android:scaleX="0.5" android:scaleY="0.5" android:pivotX="480" android:pivotY="480" android:translateY="480">
        <path android:fillColor="#FFFFFF" android:pathData="{path}" />
    </group>
</vector>
""")
PY
```

`res/mipmap-anydpi/ic_launcher.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_foreground" />
</adaptive-icon>
```

Add `<color name="launcher_background">#066A61</color>` to a new `res/values/colors.xml`.

- [ ] **Step 3: Write the failing navigator and settings tests**

`AppNavigatorTest.kt`:

```kotlin
package vn.shopnexus.app2

import androidx.compose.runtime.mutableStateOf
import androidx.navigation3.runtime.NavBackStack
import androidx.navigation3.runtime.NavKey
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import vn.shopnexus.core.navigation.CategoriesRoute
import vn.shopnexus.core.navigation.ChatRoute
import vn.shopnexus.core.navigation.HomeRoute
import vn.shopnexus.core.navigation.InboxRoute
import vn.shopnexus.core.navigation.ListingRoute
import vn.shopnexus.core.navigation.PlaceholderRoute
import vn.shopnexus.core.navigation.TopLevelRoutes

class AppNavigatorTest {
    private val state = NavigationState(
        startRoute = HomeRoute,
        topLevelRoute = mutableStateOf<NavKey>(HomeRoute),
        backStacks = TopLevelRoutes.associateWith { NavBackStack(it) },
    )
    private val navigator = AppNavigator(state)

    @Test
    fun pushingStaysInTheCurrentTabAndHidesTheBar() {
        navigator.push(ListingRoute("p-iphone13"))
        assertThat(state.currentStack.toList()).containsExactly(HomeRoute, ListingRoute("p-iphone13")).inOrder()
        assertThat(state.atRoot).isFalse()
    }

    @Test
    fun eachTabKeepsItsOwnStack() {
        navigator.push(ListingRoute("p-iphone13"))
        navigator.selectTab(CategoriesRoute)
        navigator.push(PlaceholderRoute(2, "Category"))
        navigator.selectTab(HomeRoute)
        assertThat(state.currentStack.last()).isEqualTo(ListingRoute("p-iphone13"))
        navigator.selectTab(CategoriesRoute)
        assertThat(state.currentStack.last()).isEqualTo(PlaceholderRoute(2, "Category"))
    }

    @Test
    fun selectingTheCurrentTabReturnsToItsRoot() {
        navigator.push(ListingRoute("p-iphone13"))
        navigator.push(ChatRoute("d-kiet"))
        navigator.selectTab(HomeRoute)
        assertThat(state.currentStack.toList()).containsExactly(HomeRoute)
    }

    @Test
    fun backAtATabRootGoesToKhamPha() {
        navigator.selectTab(InboxRoute)
        navigator.back()
        assertThat(state.topLevelRoute).isEqualTo(HomeRoute)
    }

    @Test
    fun aDeepLinkOpensOnKhamPhaWithoutDuplicates() {
        navigator.selectTab(InboxRoute)
        navigator.open(ChatRoute("d-kiet"))
        navigator.open(ChatRoute("d-kiet"))
        assertThat(state.topLevelRoute).isEqualTo(HomeRoute)
        assertThat(state.currentStack.toList()).containsExactly(HomeRoute, ChatRoute("d-kiet")).inOrder()
    }
}
```

`ThemeSettingsTest.kt`:

```kotlin
package vn.shopnexus.app2

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import vn.shopnexus.core.designsystem.theme.ThemeMode

class ThemeSettingsTest {
    @get:Rule val folder = TemporaryFolder()

    @Test
    fun defaultsToSystemAndBrandAndRemembersChanges() = runTest {
        val store = PreferenceDataStoreFactory.create(scope = backgroundScope) { folder.newFile("settings.preferences_pb") }
        val settings = ThemeSettings(store)
        assertThat(settings.mode.first()).isEqualTo(ThemeMode.SYSTEM)
        assertThat(settings.dynamicColor.first()).isFalse()
        settings.setMode(ThemeMode.DARK)
        settings.setDynamicColor(true)
        assertThat(settings.mode.first()).isEqualTo(ThemeMode.DARK)
        assertThat(settings.dynamicColor.first()).isTrue()
    }
}
```

`PreferenceDataStoreFactory.create` needs a file that does not exist yet; if it complains, use `java.io.File(folder.root, "settings.preferences_pb")` instead of `newFile`.

Run: `./gradlew :app:testDebugUnitTest`
Expected: FAIL, unresolved `NavigationState`, `AppNavigator`, `ThemeSettings`.

- [ ] **Step 4: Write the navigation state, the navigator and the app composable**

`AppNavigation.kt`:

```kotlin
package vn.shopnexus.app2

import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSerializable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.navigation3.rememberViewModelStoreNavEntryDecorator
import androidx.navigation3.runtime.NavBackStack
import androidx.navigation3.runtime.NavEntry
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberDecoratedNavEntries
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.runtime.rememberSaveableStateHolderNavEntryDecorator
import androidx.navigation3.runtime.serialization.NavKeySerializer
import androidx.navigation3.ui.NavDisplay
import androidx.savedstate.compose.serialization.serializers.MutableStateSerializer
import vn.shopnexus.core.designsystem.component.NavItem
import vn.shopnexus.core.designsystem.component.ShopNexusNavigationBar
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.navigation.EntryInstaller
import vn.shopnexus.core.navigation.HomeRoute
import vn.shopnexus.core.navigation.Navigator
import vn.shopnexus.core.navigation.TopLevelRoutes

/** One back stack per tab. The start tab stays under the current one, so people leave the app through Khám phá. */
class NavigationState(
    val startRoute: NavKey,
    topLevelRoute: MutableState<NavKey>,
    val backStacks: Map<NavKey, NavBackStack<NavKey>>,
) {
    var topLevelRoute: NavKey by topLevelRoute

    val currentStack: NavBackStack<NavKey> get() = backStacks.getValue(topLevelRoute)

    /** At a tab's root the navigation bar shows; pushed screens hide it. */
    val atRoot: Boolean get() = currentStack.size == 1

    @Composable
    fun toDecoratedEntries(entryProvider: (NavKey) -> NavEntry<NavKey>): List<NavEntry<NavKey>> {
        val decorated = backStacks.mapValues { (_, stack) ->
            rememberDecoratedNavEntries(
                backStack = stack,
                entryDecorators = listOf(
                    rememberSaveableStateHolderNavEntryDecorator<NavKey>(),
                    rememberViewModelStoreNavEntryDecorator<NavKey>(),
                ),
                entryProvider = entryProvider,
            )
        }
        val inUse = if (topLevelRoute == startRoute) listOf(startRoute) else listOf(startRoute, topLevelRoute)
        return inUse.flatMap { decorated[it].orEmpty() }
    }
}

@Composable
fun rememberNavigationState(startRoute: NavKey, topLevelRoutes: List<NavKey>): NavigationState {
    val topLevelRoute = rememberSerializable(startRoute, topLevelRoutes, serializer = MutableStateSerializer(NavKeySerializer())) {
        mutableStateOf(startRoute)
    }
    val backStacks = topLevelRoutes.associateWith { rememberNavBackStack(it) }
    return remember(startRoute, topLevelRoutes) { NavigationState(startRoute, topLevelRoute, backStacks) }
}

class AppNavigator(val state: NavigationState) : Navigator {
    override fun push(route: NavKey) {
        if (route in state.backStacks.keys) selectTab(route) else state.currentStack.add(route)
    }

    override fun back() {
        val stack = state.currentStack
        if (stack.size == 1) state.topLevelRoute = state.startRoute else stack.removeAt(stack.lastIndex)
    }

    override fun selectTab(tab: NavKey) {
        if (tab == state.topLevelRoute) {
            val stack = state.currentStack
            while (stack.size > 1) stack.removeAt(stack.lastIndex)
        } else {
            state.topLevelRoute = tab
        }
    }

    /** A deep link opens on Khám phá, once. */
    fun open(route: NavKey) {
        state.topLevelRoute = state.startRoute
        if (state.currentStack.last() != route) state.currentStack.add(route)
    }
}

@Composable
fun ShopNexusApp(installers: Set<EntryInstaller>, deepLink: NavKey?, onDeepLinkHandled: () -> Unit) {
    val state = rememberNavigationState(HomeRoute, TopLevelRoutes)
    val navigator = remember(state) { AppNavigator(state) }
    val provider = remember(installers, navigator) {
        entryProvider<NavKey> { installers.forEach { it.install(this, navigator) } }
    }
    LaunchedEffect(deepLink) {
        if (deepLink != null) {
            navigator.open(deepLink)
            onDeepLinkHandled()
        }
    }
    val tabs = listOf(
        NavItem(stringResource(R.string.tab_home), Symbol.Home),
        NavItem(stringResource(R.string.tab_categories), Symbol.GridView),
        NavItem(stringResource(R.string.tab_inbox), Symbol.Chat),
        NavItem(stringResource(R.string.tab_me), Symbol.Person),
    )
    Scaffold(
        contentWindowInsets = WindowInsets(0.dp),
        bottomBar = {
            if (state.atRoot) {
                ShopNexusNavigationBar(
                    items = tabs,
                    selected = TopLevelRoutes.indexOf(state.topLevelRoute),
                    onSelect = { navigator.selectTab(TopLevelRoutes[it]) },
                )
            }
        },
    ) { padding ->
        NavDisplay(
            entries = state.toDecoratedEntries(provider),
            onBack = navigator::back,
            modifier = Modifier.padding(padding).consumeWindowInsets(padding),
        )
    }
}
```

The Tin nhắn badge comes with the inbox in stage 3; stage 1 has no unread count to show.

- [ ] **Step 5: Write the settings, the application and the activity**

`ThemeSettings.kt`:

```kotlin
package vn.shopnexus.app2

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import vn.shopnexus.core.designsystem.theme.ThemeMode

/** "Giao diện tối" and "Màu theo hình nền". Tôi sets them in stage 5; the debug panel sets them now. */
@Singleton
class ThemeSettings @Inject constructor(private val store: DataStore<Preferences>) {
    private val modeKey = stringPreferencesKey("theme_mode")
    private val dynamicKey = booleanPreferencesKey("dynamic_color")

    val mode: Flow<ThemeMode> = store.data.map { p ->
        p[modeKey]?.let { runCatching { ThemeMode.valueOf(it) }.getOrNull() } ?: ThemeMode.SYSTEM
    }
    val dynamicColor: Flow<Boolean> = store.data.map { it[dynamicKey] ?: false }

    suspend fun setMode(mode: ThemeMode) { store.edit { it[modeKey] = mode.name } }
    suspend fun setDynamicColor(on: Boolean) { store.edit { it[dynamicKey] = on } }
}

private val Context.settingsStore by preferencesDataStore(name = "settings")

@Module
@InstallIn(SingletonComponent::class)
object SettingsModule {
    @Provides @Singleton
    fun store(@ApplicationContext context: Context): DataStore<Preferences> = context.settingsStore
}
```

`ShopNexusApplication.kt`:

```kotlin
package vn.shopnexus.app2

import android.app.Application
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.request.crossfade
import dagger.hilt.android.HiltAndroidApp

/** Coil keeps its default disk cache; photos fade in over the surfaceContainerHigh placeholder. */
@HiltAndroidApp
class ShopNexusApplication : Application(), SingletonImageLoader.Factory {
    override fun newImageLoader(context: PlatformContext): ImageLoader =
        ImageLoader.Builder(context).crossfade(true).build()
}
```

`MainActivity.kt`:

```kotlin
package vn.shopnexus.app2

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation3.runtime.NavKey
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject
import vn.shopnexus.core.designsystem.theme.ShopNexusTheme
import vn.shopnexus.core.designsystem.theme.ThemeMode
import vn.shopnexus.core.navigation.DeepLinks
import vn.shopnexus.core.navigation.EntryInstaller

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    @Inject lateinit var installers: Set<@JvmSuppressWildcards EntryInstaller>
    @Inject lateinit var settings: ThemeSettings

    private var deepLink by mutableStateOf<NavKey?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) deepLink = intent.deepLink()
        setContent {
            val mode by settings.mode.collectAsStateWithLifecycle(ThemeMode.SYSTEM)
            val dynamic by settings.dynamicColor.collectAsStateWithLifecycle(false)
            ShopNexusTheme(themeMode = mode, dynamicColor = dynamic) {
                DebugHost {
                    ShopNexusApp(installers, deepLink, onDeepLinkHandled = { deepLink = null })
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.deepLink()?.let { deepLink = it }
    }

    private fun Intent.deepLink(): NavKey? = data?.toString()?.let(DeepLinks::parse)
}
```

`app2/app/src/release/kotlin/vn/shopnexus/app2/DebugHost.kt`:

```kotlin
package vn.shopnexus.app2

import androidx.compose.runtime.Composable

/** Release builds have no debug panel. */
@Composable
fun DebugHost(content: @Composable () -> Unit) = content()
```

`app2/app/src/debug/kotlin/vn/shopnexus/app2/DebugHost.kt`, a pass-through until Task 23 builds the panel:

```kotlin
package vn.shopnexus.app2

import androidx.compose.runtime.Composable

@Composable
fun DebugHost(content: @Composable () -> Unit) = content()
```

- [ ] **Step 6: Run the tests and build the app**

Run: `./gradlew :app:testDebugUnitTest`
Expected: PASS, 6 tests.

Run: `./gradlew :app:assembleDebug`
Expected: BUILD SUCCESSFUL. Hilt checks the graph at compile time: the `EntryInstaller` set holds the placeholder installer, and no `HomeRoute` entry exists yet, so the app is not launched until Task 19 adds Khám phá.

Run: `./gradlew check`
Expected: PASS, including `:app:checkNoRawColors`.

- [ ] **Step 7: Commit**

```bash
git add build-logic settings.gradle.kts app
git commit -m "feat(app): add the activity, one back stack per tab and the theme settings

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```


---

### Task 19: Khám phá (Home)

The first tab: search bar, location and bell, the hero carousel, categories, "Gần bạn", "Gợi ý cho bạn" with interest chips, pull to refresh, saving, and the FAB menu. Controls for screens of later stages push `PlaceholderRoute` with the stage number.

**Files:**
- Create in `app2/core/designsystem/src/main/kotlin/vn/shopnexus/core/designsystem/component/`: `Messages.kt`, `States.kt`
- Modify: `app2/core/designsystem/src/main/res/values/strings.xml`
- Create: `app2/core/testing/src/main/kotlin/vn/shopnexus/core/testing/Clipping.kt`
- Modify: `app2/settings.gradle.kts` (add `include(":feature:discover")`), `app2/app/build.gradle.kts` (add `implementation(project(":feature:discover"))`)
- Create: `app2/feature/discover/build.gradle.kts`, `app2/feature/discover/src/main/res/values/strings.xml`, `app2/feature/discover/src/test/resources/robolectric.properties` (`sdk=36`)
- Create in `app2/feature/discover/src/main/kotlin/vn/shopnexus/feature/discover/`: `DiscoverInstaller.kt`, `home/HomeViewModel.kt`, `home/HomeScreen.kt`, `home/HomeTop.kt`, `home/HeroCarousel.kt`, `home/CategoryRow.kt`
- Test: `app2/feature/discover/src/test/kotlin/vn/shopnexus/feature/discover/home/HomeViewModelTest.kt`
- Test: `app2/feature/discover/src/test/kotlin/vn/shopnexus/feature/discover/home/HomeScreenTest.kt`

**Interfaces:**
- Consumes: `HomeRepository`, `ListingRepository`, fakes, `Fixtures` (Tasks 10–12); components (Tasks 13–16); routes and `EntryInstaller` (Task 17).
- Produces:
  ```kotlin
  // :core:designsystem
  data class UiMessage(@StringRes val text: Int, val args: List<Any> = emptyList(), @StringRes val action: Int? = null, val onAction: (() -> Unit)? = null)
  @Composable fun MessageEffect(messages: Flow<UiMessage>, host: SnackbarHostState)   // 4 s, or 6 s with an action
  @Composable fun ErrorState(message: String, onRetry: () -> Unit, modifier: Modifier = Modifier)
  // R.string.retry "Thử lại", undo "Hoàn tác", view "Xem", load_failed, save_failed, send_failed "Chưa gửi được. Thử lại"
  // :core:testing
  fun SemanticsNodeInteractionsProvider.assertNoClippedText()
  // :feature:discover
  sealed interface HomeContent { data object Loading; data object Failed; data class Ready(val feed: HomeFeed) }
  data class HomeUiState(val content: HomeContent = HomeContent.Loading, val refreshing: Boolean = false, val interests: List<String> = emptyList())
  sealed interface HomeEvent { Retry; Refresh; ToggleSave(listing); RemoveInterest(label) }
  class HomeViewModel : ViewModel { val state: StateFlow<HomeUiState>; val messages: Flow<UiMessage>; fun onEvent(event: HomeEvent) }
  @Composable fun HomeScreen(state: HomeUiState, onEvent: (HomeEvent) -> Unit, onNavigate: (NavKey) -> Unit,
                             snackbar: SnackbarHostState, modifier: Modifier = Modifier, animate: Boolean = true)
  class DiscoverInstaller : EntryInstaller   // HomeRoute now, ListingRoute from Task 20
  ```

- [ ] **Step 1: Add the shared message, error and clipping helpers**

Add to `:core:designsystem` `strings.xml`:

```xml
    <string name="retry">Thử lại</string>
    <string name="undo">Hoàn tác</string>
    <string name="view">Xem</string>
    <string name="load_failed">Chưa tải được. Thử lại</string>
    <string name="save_failed">Chưa lưu được. Thử lại</string>
    <string name="send_failed">Chưa gửi được. Thử lại</string>
```

`component/Messages.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.annotation.StringRes
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch

/** A snackbar a ViewModel asks for. Every reversible action carries "Hoàn tác" as its action. */
data class UiMessage(
    @StringRes val text: Int,
    val args: List<Any> = emptyList(),
    @StringRes val action: Int? = null,
    val onAction: (() -> Unit)? = null,
)

/** Shows [messages] one after another: 4 s, or 6 s when there is an action. */
@Composable
fun MessageEffect(messages: Flow<UiMessage>, host: SnackbarHostState) {
    val resources = LocalContext.current.resources
    LaunchedEffect(messages, host) {
        messages.collect { m ->
            coroutineScope {
                val timer = launch {
                    delay(if (m.action != null) 6_000 else 4_000)
                    host.currentSnackbarData?.dismiss()
                }
                val result = host.showSnackbar(
                    message = resources.getString(m.text, *m.args.toTypedArray()),
                    actionLabel = m.action?.let(resources::getString),
                    duration = SnackbarDuration.Indefinite,
                )
                timer.cancel()
                if (result == SnackbarResult.ActionPerformed) m.onAction?.invoke()
            }
        }
    }
}
```

`component/States.kt`:

```kotlin
package vn.shopnexus.core.designsystem.component

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import vn.shopnexus.core.designsystem.R
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon

/** A failed read: what did not load and "Thử lại". */
@Composable
fun ErrorState(message: String, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        SymbolIcon(Symbol.WifiOff, contentDescription = null, size = 48.dp, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(message, style = MaterialTheme.typography.bodyLarge, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 16.dp))
        FilledTonalButton(onClick = onRetry, modifier = Modifier.padding(top = 16.dp).heightIn(min = 48.dp)) {
            SymbolIcon(Symbol.Refresh, contentDescription = null, size = 18.dp)
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.retry))
        }
    }
}
```

`app2/core/testing/src/main/kotlin/vn/shopnexus/core/testing/Clipping.kt`:

```kotlin
package vn.shopnexus.core.testing

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteractionsProvider
import androidx.compose.ui.text.TextLayoutResult

/**
 * Fails when a text is cut off: its last laid-out line ends below the box it was given, or a
 * single line runs past its width. Text that ellipsizes at its maxLines passes.
 */
fun SemanticsNodeInteractionsProvider.assertNoClippedText() {
    val nodes = onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsActions.GetTextLayoutResult), useUnmergedTree = true)
        .fetchSemanticsNodes()
    val cut = nodes.flatMap { node ->
        val results = mutableListOf<TextLayoutResult>()
        node.config[SemanticsActions.GetTextLayoutResult].action?.invoke(results)
        results.filter { r ->
            r.lineCount > 0 && (r.getLineBottom(r.lineCount - 1) > r.size.height + 0.5f || r.didOverflowWidth)
        }.map { "\"${it.layoutInput.text}\" needs ${it.getLineBottom(it.lineCount - 1)} px, has ${it.size.height} px" }
    }
    check(cut.isEmpty()) { "Text is cut off:\n" + cut.joinToString("\n") }
}
```

- [ ] **Step 2: Create the module and its strings**

Add `include(":feature:discover")` to `settings.gradle.kts` and `implementation(project(":feature:discover"))` to `app/build.gradle.kts`.

`app2/feature/discover/build.gradle.kts`:

```kotlin
plugins {
    id("shopnexus.android.feature")
}

android {
    namespace = "vn.shopnexus.feature.discover"
}
```

`app2/feature/discover/src/main/res/values/strings.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="search_open">Tìm kiếm</string>
    <string name="photo_search">Tìm bằng ảnh</string>
    <string name="notifications">Thông báo</string>
    <string name="notifications_unread">Thông báo, có tin mới</string>
    <string name="area">Khu vực</string>
    <string name="featured">Nổi bật</string>
    <string name="hero_pause">Tạm dừng</string>
    <string name="hero_play">Phát</string>
    <string name="nearby">Gần bạn</string>
    <string name="for_you">Gợi ý cho bạn</string>
    <string name="interests">Sở thích AI suy ra</string>
    <string name="remove_interest">Bỏ %1$s</string>
    <string name="interest_removed">Đã bỏ %1$s</string>
    <string name="home_fresh">%1$d tin mới quanh bạn</string>
    <string name="home_no_fresh">Chưa có tin mới quanh bạn</string>
    <string name="home_failed">Chưa tải được Khám phá.</string>
    <string name="post">Đăng tin</string>
    <string name="post_draft">Tiếp tục nháp</string>
    <string name="post_photo">Chụp ảnh</string>
    <string name="post_video">Quay video</string>
</resources>
```

- [ ] **Step 3: Write the failing ViewModel test**

`HomeViewModelTest.kt`:

```kotlin
package vn.shopnexus.feature.discover.home

import app.cash.turbine.test
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.Test
import vn.shopnexus.core.data.fake.FailurePolicy
import vn.shopnexus.core.data.fake.FakeHomeRepository
import vn.shopnexus.core.data.fake.FakeListingRepository
import vn.shopnexus.core.data.fake.FakeWorld
import vn.shopnexus.core.testing.MainDispatcherRule
import vn.shopnexus.feature.discover.R

@OptIn(ExperimentalCoroutinesApi::class)
class HomeViewModelTest {
    @get:Rule val main = MainDispatcherRule()
    private val world = FakeWorld()
    private val failures = FailurePolicy(latencyMillis = 0)
    private fun viewModel() = HomeViewModel(FakeHomeRepository(world, failures), FakeListingRepository(world, failures))

    private fun HomeUiState.feed() = (content as HomeContent.Ready).feed

    @Test
    fun loadsTheFeed() = runTest {
        val vm = viewModel()
        vm.state.test {
            var s = awaitItem()
            while (s.content !is HomeContent.Ready) s = awaitItem()
            assertThat(s.feed().nearby).hasSize(5)
            assertThat(s.interests).containsExactly("Xe đạp", "Máy ảnh", "iPhone", "Nội thất gỗ").inOrder()
        }
    }

    @Test
    fun aFailedLoadShowsTheErrorAndRetryLoads() = runTest {
        failures.rate = 1.0
        val vm = viewModel()
        vm.state.test {
            var s = awaitItem()
            while (s.content !is HomeContent.Failed) s = awaitItem()
            failures.rate = 0.0
            vm.onEvent(HomeEvent.Retry)
            while (s.content !is HomeContent.Ready) s = awaitItem()
        }
    }

    @Test
    fun refreshAnnouncesTheNewListingsOnce() = runTest {
        val vm = viewModel()
        backgroundScope.launch { vm.state.collect {} }
        vm.messages.test {
            vm.onEvent(HomeEvent.Refresh)
            assertThat(awaitItem()).isEqualTo(vn.shopnexus.core.designsystem.component.UiMessage(R.string.home_fresh, listOf(2)))
            vm.onEvent(HomeEvent.Refresh)
            assertThat(awaitItem().text).isEqualTo(R.string.home_no_fresh)
        }
        assertThat(vm.state.value.feed().nearby).hasSize(7)
        assertThat(vm.state.value.refreshing).isFalse()
    }

    @Test
    fun savingShowsAtOnceAndRollsBackWhenItFails() = runTest {
        val vm = viewModel()
        backgroundScope.launch { vm.state.collect {} }
        advanceUntilIdle()
        val bike = vm.state.value.feed().nearby.first { !it.saved }
        failures.rate = 1.0
        failures.latencyMillis = 300
        vm.messages.test {
            vm.onEvent(HomeEvent.ToggleSave(bike))
            assertThat(vm.state.value.feed().nearby.first { it.id == bike.id }.saved).isTrue()
            assertThat(awaitItem().text).isEqualTo(vn.shopnexus.core.designsystem.R.string.save_failed)
        }
        assertThat(vm.state.value.feed().nearby.first { it.id == bike.id }.saved).isFalse()
    }

    @Test
    fun removingAnInterestOffersUndo() = runTest {
        val vm = viewModel()
        backgroundScope.launch { vm.state.collect {} }
        advanceUntilIdle()
        vm.messages.test {
            vm.onEvent(HomeEvent.RemoveInterest("Xe đạp"))
            assertThat(vm.state.value.interests).doesNotContain("Xe đạp")
            awaitItem().onAction!!.invoke()
        }
        assertThat(vm.state.value.interests.first()).isEqualTo("Xe đạp")
    }
}
```

Each test that reads `state.value` starts a collector in `backgroundScope` first, because `state` only runs while someone collects it.

Run: `./gradlew :feature:discover:testDebugUnitTest`
Expected: FAIL, `Unresolved reference 'HomeViewModel'`.

- [ ] **Step 4: Write the ViewModel**

`home/HomeViewModel.kt`:

```kotlin
package vn.shopnexus.feature.discover.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import vn.shopnexus.core.data.HomeRepository
import vn.shopnexus.core.data.ListingRepository
import vn.shopnexus.core.designsystem.component.UiMessage
import vn.shopnexus.core.model.HomeFeed
import vn.shopnexus.core.model.ListingId
import vn.shopnexus.core.model.ListingSummary
import vn.shopnexus.feature.discover.R
import vn.shopnexus.core.designsystem.R as DesignR

sealed interface HomeContent {
    data object Loading : HomeContent
    data object Failed : HomeContent
    data class Ready(val feed: HomeFeed) : HomeContent
}

data class HomeUiState(
    val content: HomeContent = HomeContent.Loading,
    val refreshing: Boolean = false,
    val interests: List<String> = emptyList(),
)

sealed interface HomeEvent {
    data object Retry : HomeEvent
    data object Refresh : HomeEvent
    data class ToggleSave(val listing: ListingSummary) : HomeEvent
    data class RemoveInterest(val label: String) : HomeEvent
}

@OptIn(ExperimentalCoroutinesApi::class)
@HiltViewModel
class HomeViewModel @Inject constructor(
    private val home: HomeRepository,
    private val listings: ListingRepository,
) : ViewModel() {
    private val attempt = MutableStateFlow(0)
    private val refreshing = MutableStateFlow(false)
    /** Saves in flight show at once; a failed one falls back to what the repository says. */
    private val pendingSaves = MutableStateFlow<Map<ListingId, Boolean>>(emptyMap())
    private val removed = MutableStateFlow<Set<String>>(emptySet())
    private val outbox = Channel<UiMessage>(Channel.BUFFERED)
    val messages: Flow<UiMessage> = outbox.receiveAsFlow()

    private val content: Flow<HomeContent> = attempt.flatMapLatest {
        home.feed()
            .map<HomeFeed, HomeContent> { HomeContent.Ready(it) }
            .onStart { emit(HomeContent.Loading) }
            .catch { emit(HomeContent.Failed) }
    }

    val state: StateFlow<HomeUiState> = combine(content, refreshing, pendingSaves, removed) { c, r, pending, gone ->
        val shown = if (c is HomeContent.Ready) HomeContent.Ready(c.feed.withSaves(pending)) else c
        HomeUiState(shown, r, (c as? HomeContent.Ready)?.feed?.interests.orEmpty().filterNot { it in gone })
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), HomeUiState())

    fun onEvent(event: HomeEvent) {
        when (event) {
            HomeEvent.Retry -> attempt.update { it + 1 }
            HomeEvent.Refresh -> refresh()
            is HomeEvent.ToggleSave -> toggleSave(event.listing)
            is HomeEvent.RemoveInterest -> {
                removed.update { it + event.label }
                outbox.trySend(UiMessage(R.string.interest_removed, listOf(event.label), DesignR.string.undo) { removed.update { it - event.label } })
            }
        }
    }

    private fun refresh() {
        if (refreshing.value) return
        refreshing.value = true
        viewModelScope.launch {
            home.refresh()
                .onSuccess { n -> outbox.send(if (n > 0) UiMessage(R.string.home_fresh, listOf(n)) else UiMessage(R.string.home_no_fresh)) }
                .onFailure { outbox.send(UiMessage(DesignR.string.load_failed)) }
            refreshing.value = false
        }
    }

    private fun toggleSave(listing: ListingSummary) {
        val target = !(pendingSaves.value[listing.id] ?: listing.saved)
        pendingSaves.update { it + (listing.id to target) }
        viewModelScope.launch {
            val result = listings.setSaved(listing.id, target)
            pendingSaves.update { it - listing.id }
            result.onFailure { outbox.send(UiMessage(DesignR.string.save_failed)) }
        }
    }
}

private fun List<ListingSummary>.withSaves(pending: Map<ListingId, Boolean>) =
    if (pending.isEmpty()) this else map { s -> pending[s.id]?.let { s.copy(saved = it) } ?: s }

private fun HomeFeed.withSaves(pending: Map<ListingId, Boolean>) =
    copy(nearby = nearby.withSaves(pending), forYou = forYou.withSaves(pending))
```

Run: `./gradlew :feature:discover:testDebugUnitTest`
Expected: PASS, 5 tests.

- [ ] **Step 5: Write the failing screen test**

`HomeScreenTest.kt`:

```kotlin
package vn.shopnexus.feature.discover.home

import androidx.compose.material3.SnackbarHostState
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.navigation3.runtime.NavKey
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import vn.shopnexus.core.data.fake.Fixtures
import vn.shopnexus.core.navigation.ListingRoute
import vn.shopnexus.core.navigation.PlaceholderRoute
import vn.shopnexus.core.testing.Variant
import vn.shopnexus.core.testing.VariantFrame
import vn.shopnexus.core.testing.assertNoClippedText
import vn.shopnexus.core.testing.captureScreen
import vn.shopnexus.core.testing.captureVariants
import vn.shopnexus.core.testing.fakeImages

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w412dp-h915dp-xhdpi")
class HomeScreenTest {
    @get:Rule val compose = createComposeRule()
    private val ready = HomeUiState(HomeContent.Ready(Fixtures.home()), interests = Fixtures.home().interests)
    private val pushed = mutableListOf<NavKey>()
    private val events = mutableListOf<HomeEvent>()

    private fun show(state: HomeUiState) {
        fakeImages()
        compose.setContent {
            VariantFrame(Variant.LIGHT) {
                HomeScreen(state, { events += it }, { pushed += it }, SnackbarHostState(), animate = false)
            }
        }
    }

    @Test
    fun cardsOpenListingsAndLaterScreensOpenPlaceholders() {
        show(ready)
        compose.onNodeWithContentDescription("Xem iPhone X 64GB, pin 86%, máy zin chưa sửa").performClick()
        compose.onNodeWithContentDescription("Thông báo, có tin mới").performClick()
        assertThat(pushed).containsExactly(ListingRoute("l-1510557880182"), PlaceholderRoute(2, "Thông báo")).inOrder()
    }

    @Test
    fun theFabMenuOffersTheThreeWaysToPost() {
        show(ready)
        compose.onNodeWithText("Đăng tin").performClick()
        compose.onNodeWithText("Quay video").performClick()
        assertThat(pushed).containsExactly(PlaceholderRoute(4, "Quay video"))
    }

    @Test
    fun theHeroPausesAndPlays() {
        show(ready)
        // Playing runs the 5 s timer and slides on and on, so the clock moves by hand here.
        compose.mainClock.autoAdvance = false
        compose.onNodeWithContentDescription("Phát").performClick()
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithContentDescription("Tạm dừng").performClick()
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithContentDescription("Phát").assertExists()
    }

    @Test
    fun aFailedLoadRetries() {
        show(HomeUiState(HomeContent.Failed))
        compose.onNodeWithText("Thử lại").performClick()
        assertThat(events).containsExactly(HomeEvent.Retry)
    }

    @Test
    fun textFitsAtFontScale130() {
        fakeImages()
        compose.setContent { VariantFrame(Variant.FONT_130) { HomeScreen(ready, {}, {}, SnackbarHostState(), animate = false) } }
        compose.assertNoClippedText()
    }

    @Test
    fun screenshots() = compose.captureVariants("home") { HomeScreen(ready, {}, {}, SnackbarHostState(), animate = false) }

    @Test
    fun loadingScreenshot() = compose.captureScreen("home-loading") { HomeScreen(HomeUiState(), {}, {}, SnackbarHostState(), animate = false) }

    @Test
    fun failedScreenshot() = compose.captureScreen("home-failed") { HomeScreen(HomeUiState(HomeContent.Failed), {}, {}, SnackbarHostState(), animate = false) }
}
```

With `animate = false` the hero does not autoplay and the search hints do not rotate, so the hero starts paused and offers "Phát".

Run: `./gradlew :feature:discover:testDebugUnitTest --tests "*HomeScreenTest*"`
Expected: FAIL, `Unresolved reference 'HomeScreen'`.

- [ ] **Step 6: Write the top of Home**

`home/HomeTop.kt`:

```kotlin
package vn.shopnexus.feature.discover.home

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import vn.shopnexus.core.designsystem.component.LocalDebugTrigger
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.feature.discover.R

/** A 56 dp pill that opens search. The hint rotates every 3.5 s; two hints show that a whole sentence works. */
@Composable
internal fun SearchBar(hints: List<String>, animate: Boolean, onOpen: () -> Unit, onPhoto: () -> Unit, modifier: Modifier = Modifier) {
    var index by rememberSaveable { mutableIntStateOf(0) }
    LaunchedEffect(hints, animate) {
        if (animate && hints.size > 1) while (true) {
            delay(3_500)
            index = (index + 1) % hints.size
        }
    }
    val c = MaterialTheme.colorScheme
    Row(
        modifier
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .fillMaxWidth()
            .height(56.dp)
            .clip(CircleShape)
            .background(c.surfaceContainerHigh)
            .clickable(onClickLabel = stringResource(R.string.search_open), role = Role.Button, onClick = onOpen)
            .padding(start = 16.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SymbolIcon(Symbol.Search, contentDescription = null, tint = c.onSurfaceVariant)
        AnimatedContent(
            targetState = hints.getOrElse(index) { "" },
            transitionSpec = { (slideInVertically { it } + fadeIn()) togetherWith (slideOutVertically { -it } + fadeOut()) },
            label = "hint",
            modifier = Modifier.weight(1f).padding(start = 12.dp),
        ) { hint ->
            Text(hint, style = MaterialTheme.typography.bodyLarge, color = c.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        IconButton(onClick = onPhoto) { SymbolIcon(Symbol.PhotoCamera, stringResource(R.string.photo_search)) }
    }
}

/** The location pill (a long press opens the debug panel in debug builds) and the bell with its unread dot. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun LocationRow(district: String, unread: Int, onArea: () -> Unit, onBell: () -> Unit, modifier: Modifier = Modifier) {
    val c = MaterialTheme.colorScheme
    Row(modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(
            Modifier
                .minimumInteractiveComponentSize()
                .clip(CircleShape)
                .background(c.surfaceContainerLow)
                .combinedClickable(onClickLabel = stringResource(R.string.area), onClick = onArea, onLongClick = LocalDebugTrigger.current)
                .padding(start = 12.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SymbolIcon(Symbol.LocationOn, contentDescription = null, size = 18.dp, tint = c.primary)
            Text(district, style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            SymbolIcon(Symbol.KeyboardArrowDown, contentDescription = null, size = 18.dp, tint = c.onSurfaceVariant)
        }
        Spacer(Modifier.weight(1f))
        IconButton(onClick = onBell) {
            BadgedBox(badge = { if (unread > 0) Badge() }) {
                SymbolIcon(
                    Symbol.Notifications,
                    stringResource(if (unread > 0) R.string.notifications_unread else R.string.notifications),
                )
            }
        }
    }
}
```

- [ ] **Step 7: Write the hero carousel and the category row**

`home/HeroCarousel.kt`:

```kotlin
package vn.shopnexus.feature.discover.home

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.carousel.HorizontalMultiBrowseCarousel
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.material3.carousel.rememberCarouselState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.core.designsystem.theme.Corners
import vn.shopnexus.core.model.HeroSlide
import vn.shopnexus.feature.discover.R

private const val SLIDE_MS = 5_000

/**
 * The M3 Expressive hero: a 346 dp focused slide with the next one peeking 26 dp. Under it a pill
 * track with one dot per slide, the active dot filling as the 5 s timer runs, and a pause button.
 * With [animate] off (reduced motion, tests) it starts paused.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
internal fun HeroCarousel(slides: List<HeroSlide>, animate: Boolean, onOpen: (HeroSlide) -> Unit, modifier: Modifier = Modifier) {
    val state = rememberCarouselState { slides.size }
    var paused by rememberSaveable { mutableStateOf(!animate) }
    val progress = remember { Animatable(0f) }
    var progressFor by remember { mutableIntStateOf(state.currentItem) }
    val current = state.currentItem
    LaunchedEffect(current, paused) {
        if (progressFor != current) {
            progress.snapTo(0f)
            progressFor = current
        }
        if (paused) return@LaunchedEffect
        progress.animateTo(1f, tween(((1f - progress.value) * SLIDE_MS).toInt(), easing = LinearEasing))
        progress.snapTo(0f)
        state.animateScrollToItem((current + 1) % slides.size)
    }
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        HorizontalMultiBrowseCarousel(
            state = state,
            preferredItemWidth = 346.dp,
            itemSpacing = 8.dp,
            minSmallItemWidth = 26.dp,
            maxSmallItemWidth = 26.dp,
            contentPadding = PaddingValues(horizontal = 16.dp),
            modifier = Modifier.padding(top = 16.dp).fillMaxWidth().height(200.dp),
        ) { i ->
            val slide = slides[i]
            val info = carouselItemDrawInfo
            Box(Modifier.fillMaxSize().maskClip(Corners.ExtraLarge).background(MaterialTheme.colorScheme.surfaceContainerHigh)) {
                AsyncImage(slide.imageUrl, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0f to Color.Transparent, 0.4f to Color.Black.copy(alpha = 0.2f), 1f to Color.Black.copy(alpha = 0.6f))))
                Column(
                    Modifier
                        .fillMaxSize()
                        .padding(16.dp)
                        .graphicsLayer {
                            val range = info.maxSize - info.minSize
                            alpha = if (range <= 0f) 1f else ((info.size - info.minSize) / range).coerceIn(0f, 1f)
                        },
                    verticalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(
                        slide.tag,
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onTertiaryContainer,
                        modifier = Modifier.background(MaterialTheme.colorScheme.tertiaryContainer, Corners.Small).padding(horizontal = 8.dp, vertical = 2.dp),
                    )
                    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(
                            slide.title,
                            style = MaterialTheme.typography.headlineSmall,
                            fontWeight = FontWeight.Medium,
                            color = Color.White,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        IconButton(onClick = { onOpen(slide) }) {
                            Box(Modifier.size(40.dp).background(Color.White, CircleShape), Alignment.Center) {
                                SymbolIcon(Symbol.ArrowForward, slide.cta, size = 22.dp, tint = MaterialTheme.colorScheme.onSurface)
                            }
                        }
                    }
                }
            }
        }
        Row(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Row(
                Modifier.height(40.dp).background(MaterialTheme.colorScheme.surfaceContainerHigh, CircleShape).padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                slides.indices.forEach { i ->
                    val width by animateDpAsState(if (i == current) 32.dp else 8.dp, MaterialTheme.motionScheme.defaultSpatialSpec(), label = "dot")
                    Box(Modifier.width(width).height(8.dp).background(MaterialTheme.colorScheme.outlineVariant, CircleShape)) {
                        if (i == current) {
                            Box(Modifier.fillMaxHeight().fillMaxWidth(progress.value).background(MaterialTheme.colorScheme.primary, CircleShape))
                        }
                    }
                }
            }
            FilledIconButton(
                onClick = { paused = !paused },
                colors = IconButtonDefaults.filledIconButtonColors(
                    containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                ),
                modifier = Modifier.minimumInteractiveComponentSize().size(40.dp),
            ) {
                SymbolIcon(
                    if (paused) Symbol.PlayArrow else Symbol.Pause,
                    stringResource(if (paused) R.string.hero_play else R.string.hero_pause),
                    size = 20.dp,
                )
            }
        }
    }
}
```

The pause button draws at 40 dp, as the design has it, inside a 48 dp touch target.

`home/CategoryRow.kt`:

```kotlin
package vn.shopnexus.feature.discover.home

import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.toShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.core.model.CategoryEntry

/** The MaterialShapes the categories carry in the data; the pill is turned 45°, as in the mockup. */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun shapeOf(name: String): Shape = when (name) {
    "Cookie9Sided" -> MaterialShapes.Cookie9Sided.toShape()
    "Clover4Leaf" -> MaterialShapes.Clover4Leaf.toShape()
    "Sunny" -> MaterialShapes.Sunny.toShape()
    "Arch" -> MaterialShapes.Arch.toShape()
    "Pill" -> MaterialShapes.Pill.toShape(startAngle = -45)
    "Gem" -> MaterialShapes.Gem.toShape()
    "Flower" -> MaterialShapes.Flower.toShape()
    "SoftBurst" -> MaterialShapes.SoftBurst.toShape()
    else -> CircleShape
}

/** Eight categories: a 64 dp shape in secondaryContainer with the icon, the label under it; they enter 30 ms apart. */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
internal fun CategoryRow(categories: List<CategoryEntry>, animate: Boolean, onOpen: (CategoryEntry) -> Unit, modifier: Modifier = Modifier) {
    val c = MaterialTheme.colorScheme
    val spec = MaterialTheme.motionScheme.defaultSpatialSpec<Float>()
    LazyRow(
        modifier.padding(top = 24.dp),
        contentPadding = PaddingValues(horizontal = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        itemsIndexed(categories, key = { _, it -> it.key }) { i, category ->
            val enter = remember { Animatable(if (animate) 0f else 1f) }
            LaunchedEffect(Unit) {
                if (animate) {
                    delay(30L * i)
                    enter.animateTo(1f, spec)
                }
            }
            Column(
                Modifier
                    .width(76.dp)
                    .graphicsLayer { alpha = enter.value; translationY = (1f - enter.value) * 24f }
                    .clickable { onOpen(category) },
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Box(Modifier.size(64.dp).background(c.secondaryContainer, shapeOf(category.shape)), Alignment.Center) {
                    SymbolIcon(Symbol.of(category.icon) ?: Symbol.GridView, contentDescription = null, size = 28.dp, tint = c.onSecondaryContainer)
                }
                Text(
                    category.label,
                    style = MaterialTheme.typography.labelMedium,
                    color = c.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}
```

- [ ] **Step 8: Write the screen and the installer**

`home/HomeScreen.kt`:

```kotlin
package vn.shopnexus.feature.discover.home

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.InputChip
import androidx.compose.material3.InputChipDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.PullToRefreshDefaults
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation3.runtime.NavKey
import vn.shopnexus.core.designsystem.component.ErrorState
import vn.shopnexus.core.designsystem.component.FabAction
import vn.shopnexus.core.designsystem.component.FabMenu
import vn.shopnexus.core.designsystem.component.ListingCardSkeleton
import vn.shopnexus.core.designsystem.component.ListingRail
import vn.shopnexus.core.designsystem.component.MessageEffect
import vn.shopnexus.core.designsystem.component.SectionHeader
import vn.shopnexus.core.designsystem.component.listingGrid
import vn.shopnexus.core.designsystem.component.rememberReducedMotion
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.core.designsystem.theme.Corners
import vn.shopnexus.core.model.HomeFeed
import vn.shopnexus.core.model.ListingSummary
import vn.shopnexus.core.navigation.ListingRoute
import vn.shopnexus.core.navigation.Navigator
import vn.shopnexus.core.navigation.PlaceholderRoute
import vn.shopnexus.feature.discover.R

@Composable
internal fun HomeEntry(navigator: Navigator, viewModel: HomeViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    MessageEffect(viewModel.messages, snackbar)
    HomeScreen(state, viewModel::onEvent, navigator::push, snackbar, animate = !rememberReducedMotion())
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun HomeScreen(
    state: HomeUiState,
    onEvent: (HomeEvent) -> Unit,
    onNavigate: (NavKey) -> Unit,
    snackbar: SnackbarHostState,
    modifier: Modifier = Modifier,
    animate: Boolean = true,
) {
    val list = rememberLazyListState()
    var fabOpen by remember { mutableStateOf(false) }
    val post = stringResource(R.string.post)
    val video = stringResource(R.string.post_video)
    val actions = listOf(
        FabAction(stringResource(R.string.post_draft), Symbol.Draft) { onNavigate(PlaceholderRoute(4, post)) },
        FabAction(stringResource(R.string.post_photo), Symbol.PhotoCamera) { onNavigate(PlaceholderRoute(4, post)) },
        FabAction(video, Symbol.Videocam) { onNavigate(PlaceholderRoute(4, video)) },
    )
    Scaffold(
        modifier = modifier,
        snackbarHost = { SnackbarHost(snackbar) },
        floatingActionButton = { FabMenu(post, actions, fabOpen, { fabOpen = it }, extended = list.isScrollingUp()) },
    ) { padding ->
        when (val content = state.content) {
            HomeContent.Loading -> HomeSkeleton(Modifier.padding(padding))
            HomeContent.Failed -> ErrorState(stringResource(R.string.home_failed), onRetry = { onEvent(HomeEvent.Retry) }, Modifier.padding(padding))
            is HomeContent.Ready -> {
                val pull = rememberPullToRefreshState()
                PullToRefreshBox(
                    isRefreshing = state.refreshing,
                    onRefresh = { onEvent(HomeEvent.Refresh) },
                    state = pull,
                    modifier = Modifier.padding(padding),
                    indicator = {
                        PullToRefreshDefaults.LoadingIndicator(
                            state = pull,
                            isRefreshing = state.refreshing,
                            modifier = Modifier.align(Alignment.TopCenter),
                            containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
                            color = MaterialTheme.colorScheme.primary,
                        )
                    },
                ) {
                    HomeFeedList(content.feed, state.interests, list, animate, onEvent, onNavigate)
                }
            }
        }
    }
}

@Composable
private fun HomeFeedList(
    feed: HomeFeed,
    interests: List<String>,
    list: LazyListState,
    animate: Boolean,
    onEvent: (HomeEvent) -> Unit,
    onNavigate: (NavKey) -> Unit,
) {
    val open = { l: ListingSummary -> onNavigate(ListingRoute(l.id.value)) }
    val save = { l: ListingSummary -> onEvent(HomeEvent.ToggleSave(l)) }
    val later = { title: String -> onNavigate(PlaceholderRoute(2, title)) }
    val search = stringResource(R.string.search_open)
    val photo = stringResource(R.string.photo_search)
    val area = stringResource(R.string.area)
    val bell = stringResource(R.string.notifications)
    val nearby = stringResource(R.string.nearby)
    val forYou = stringResource(R.string.for_you)
    val rail = rememberLazyListState()
    // New listings enter at the start of "Gần bạn"; bring the rail back to show them.
    LaunchedEffect(feed.nearby.firstOrNull()?.id) { rail.animateScrollToItem(0) }
    LazyColumn(Modifier.testTag("home-list"), state = list, contentPadding = PaddingValues(bottom = 96.dp)) {
        item(key = "search") { SearchBar(feed.searchHints, animate, onOpen = { later(search) }, onPhoto = { later(photo) }) }
        item(key = "location") { LocationRow(feed.district, feed.unreadNotifications, onArea = { later(area) }, onBell = { later(bell) }) }
        item(key = "hero") { HeroCarousel(feed.hero, animate, onOpen = { later(it.title) }) }
        item(key = "categories") { CategoryRow(feed.categories, animate, onOpen = { later(it.label) }) }
        item(key = "nearby-title") { SectionHeader(nearby, onSeeAll = { later(nearby) }) }
        item(key = "nearby") { ListingRail(feed.nearby, open, save, state = rail) }
        item(key = "for-you-title") { SectionHeader(forYou, onSeeAll = { later(forYou) }) }
        if (interests.isNotEmpty()) item(key = "interests") { InterestChips(interests) { onEvent(HomeEvent.RemoveInterest(it)) } }
        listingGrid(feed.forYou, open, save)
    }
}

/** Interests the model inferred: an AI insight, so the row starts with the sparkle. Removing one offers "Hoàn tác". */
@Composable
private fun InterestChips(interests: List<String>, onRemove: (String) -> Unit) {
    val label = stringResource(R.string.interests)
    LazyRow(
        Modifier.padding(bottom = 12.dp).semantics { contentDescription = label },
        contentPadding = PaddingValues(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        item { SymbolIcon(Symbol.AutoAwesome, contentDescription = null, filled = true, size = 20.dp, tint = MaterialTheme.colorScheme.primary) }
        items(interests, key = { it }) { interest ->
            InputChip(
                selected = false,
                onClick = { onRemove(interest) },
                label = { Text(interest) },
                trailingIcon = { SymbolIcon(Symbol.Close, stringResource(R.string.remove_interest, interest), size = 16.dp) },
                shape = CircleShape,
                colors = InputChipDefaults.inputChipColors(labelColor = MaterialTheme.colorScheme.onSurfaceVariant),
                modifier = Modifier.animateItem(),
            )
        }
    }
}

@Composable
private fun HomeSkeleton(modifier: Modifier = Modifier) {
    val fill = MaterialTheme.colorScheme.surfaceContainerHigh
    Column(modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Box(Modifier.fillMaxWidth().height(56.dp).background(fill, CircleShape))
        Box(Modifier.fillMaxWidth().height(200.dp).background(fill, Corners.ExtraLarge))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            ListingCardSkeleton(Modifier.weight(1f))
            ListingCardSkeleton(Modifier.weight(1f))
        }
    }
}

/** True while the list scrolls towards its top or rests at it; the FAB keeps its label then. */
@Composable
private fun LazyListState.isScrollingUp(): Boolean {
    var previousIndex by remember(this) { mutableIntStateOf(firstVisibleItemIndex) }
    var previousOffset by remember(this) { mutableIntStateOf(firstVisibleItemScrollOffset) }
    return remember(this) {
        derivedStateOf {
            val up = if (previousIndex != firstVisibleItemIndex) previousIndex > firstVisibleItemIndex
            else previousOffset >= firstVisibleItemScrollOffset
            previousIndex = firstVisibleItemIndex
            previousOffset = firstVisibleItemScrollOffset
            up
        }
    }.value
}
```

`DiscoverInstaller.kt`:

```kotlin
package vn.shopnexus.feature.discover

import androidx.navigation3.runtime.EntryProviderScope
import androidx.navigation3.runtime.NavKey
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dagger.multibindings.IntoSet
import javax.inject.Inject
import vn.shopnexus.core.navigation.EntryInstaller
import vn.shopnexus.core.navigation.HomeRoute
import vn.shopnexus.core.navigation.Navigator
import vn.shopnexus.feature.discover.home.HomeEntry

class DiscoverInstaller @Inject constructor() : EntryInstaller {
    override fun install(scope: EntryProviderScope<NavKey>, navigator: Navigator) = with(scope) {
        entry<HomeRoute> { HomeEntry(navigator) }
    }
}

@Module
@InstallIn(SingletonComponent::class)
abstract class DiscoverModule {
    @Binds @IntoSet abstract fun installer(impl: DiscoverInstaller): EntryInstaller
}
```

- [ ] **Step 9: Run the tests and record the screenshots**

Run: `./gradlew :feature:discover:testDebugUnitTest`
Expected: PASS, 13 tests.

Run: `./gradlew :feature:discover:recordRoborazziDebug`. Open `home-light.png` next to `app2/.superdesign/tmp/home.html` at 412 px wide. Check, top to bottom: the 56 dp search pill with "Tìm iPhone, xe đạp, sofa…" and the camera; the location pill and the bell with its dot; the hero at 346 dp with the next slide peeking, the tag in terracotta container, the white headline and the white arrow circle; the dot track and the play button; eight category shapes with labels; "Gần bạn" with the arrow circle; 160 dp rail cards. Fix any difference before going on, then run `./gradlew :feature:discover:verifyRoborazziDebug`.

- [ ] **Step 10: Walk Home on the emulator**

```bash
source ~/.local/share/shopnexus/android-env.sh
emulator -avd app2-api36 -no-snapshot-save &
adb wait-for-device
./gradlew :app:installDebug
adb shell am start -n vn.shopnexus.app2/.MainActivity
```

Check by hand: the hint rotates; the hero autoplays and pauses; pulling down at the top shows the loading indicator, then two listings enter "Gần bạn" and the snackbar says "2 tin mới quanh bạn"; a second pull says "Chưa có tin mới quanh bạn"; the heart toggles; removing "Xe đạp" offers "Hoàn tác"; the FAB collapses while scrolling down and its menu dims the whole screen including the navigation bar; tapping the iPhone 13 Pro card shows an empty screen until Task 20 (the route has no entry yet, so do not tap it now); other controls open the placeholder naming their stage. Turn on TalkBack once and check that the search pill, bell, hearts and pause button read their labels.

- [ ] **Step 11: Commit**

```bash
git add settings.gradle.kts app core/designsystem core/testing feature/discover
git commit -m "feat(discover): add Khám phá with the hero, categories, rails, refresh and the FAB menu

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 20: Listing detail

The iPhone 13 Pro page: photos and viewer, price and AI price line, seller, questions, Tình trạng, Thông tin máy, Giao dịch, Tin tương tự, the docked actions, the offer sheet, the price sheet and the report sheet.

**Files:**
- Create in `app2/feature/discover/src/main/kotlin/vn/shopnexus/feature/discover/detail/`: `ListingDetailViewModel.kt`, `ListingDetailScreen.kt`, `DetailSections.kt`, `DetailSheets.kt`, `PhotoViewer.kt`
- Modify: `app2/feature/discover/src/main/kotlin/vn/shopnexus/feature/discover/DiscoverInstaller.kt`
- Modify: `app2/feature/discover/src/main/res/values/strings.xml`
- Modify: `app2/core/testing/src/main/kotlin/vn/shopnexus/core/testing/Screenshots.kt` (add `captureAllWindows`)
- Test: `app2/feature/discover/src/test/kotlin/vn/shopnexus/feature/discover/detail/ListingDetailViewModelTest.kt`
- Test: `app2/feature/discover/src/test/kotlin/vn/shopnexus/feature/discover/detail/ListingDetailScreenTest.kt`

**Interfaces:**
- Consumes: `ListingRepository`, `DealRepository` (Task 10); `offerRange`, `parseOfferInput`, `OfferCheck`, `availablePaths`, `moneyNotes`, `MoneyStep` (Tasks 4, 5, 8); components.
- Produces:
  ```kotlin
  sealed interface DetailContent { Loading; Failed; Missing; data class Ready(val detail: ListingDetail, val ageHours: Long) }
  data class OfferSheetState(val amount: Vnd?, val note: String, val range: OfferRange, val check: OfferCheck, val chips: List<Vnd>, val sending: Boolean)
  data class DetailUiState(val content: DetailContent = DetailContent.Loading, val offer: OfferSheetState? = null, val similarHidden: Boolean = false)
  sealed interface DetailEvent { Retry; ToggleSave; OpenOffer; StepOffer(up); PickOffer(amount); TypeOffer(text); TypeNote(text);
                                 CloseOffer; SendOffer; Ask(question); HideSimilar; Report(reason) }
  class ListingDetailViewModel : ViewModel { val state; val messages: Flow<UiMessage>; val navigation: Flow<NavKey>; fun onEvent(e)
      @AssistedFactory interface Factory { fun create(route: ListingRoute): ListingDetailViewModel } }
  @Composable fun ListingDetailScreen(state: DetailUiState, onEvent: (DetailEvent) -> Unit, onNavigate: (NavKey) -> Unit,
                                      onBack: () -> Unit, snackbar: SnackbarHostState, modifier: Modifier = Modifier)
  // :core:testing
  fun captureAllWindows(name: String, variant: Variant = Variant.LIGHT)   // sheets and dialogs too
  ```

- [ ] **Step 1: Add the strings**

Append to `feature/discover/src/main/res/values/strings.xml`:

```xml
    <string name="share">Chia sẻ</string>
    <string name="more">Thêm</string>
    <string name="hide_similar">Ẩn tin tương tự</string>
    <string name="similar_hidden">Đã ẩn các tin giống tin này</string>
    <string name="report_listing">Báo cáo tin</string>
    <string name="report_banned">Hàng cấm bán</string>
    <string name="report_fake">Hàng giả, hàng nhái</string>
    <string name="report_scam">Có dấu hiệu lừa đảo</string>
    <string name="report_other">Lý do khác</string>
    <string name="report_scope">Người kiểm duyệt xem hàng cấm, hàng giả và lừa đảo. Tình trạng và giá là chuyện giữa người mua và người bán.</string>
    <string name="report_send">Gửi báo cáo</string>
    <string name="report_sent">Đã gửi báo cáo. Người kiểm duyệt sẽ xem trong 24 giờ.</string>
    <string name="photo_count">%1$d/%2$d</string>
    <string name="open_photo">Xem ảnh %1$d</string>
    <string name="insight_detail">Rẻ hơn %1$d%% so với tin tương tự</string>
    <string name="age_just_now">Vừa đăng</string>
    <string name="age_hours">%1$d giờ trước</string>
    <string name="age_days">%1$d ngày trước</string>
    <string name="rating_count">%1$s (%2$d)</string>
    <string name="sold">%1$d đã bán</string>
    <string name="reply_time">Trả lời ~%1$s</string>
    <string name="joined">Từ %1$d</string>
    <string name="verified">Đã xác minh</string>
    <string name="condition">Tình trạng</string>
    <string name="declared">Đã khai</string>
    <string name="close_up_captured">Ảnh cận chụp trong app · %1$s</string>
    <string name="all_photos_in_app">Cả %1$d ảnh chụp trong app, có dấu thời gian</string>
    <string name="some_photos_in_app">%1$d/%2$d ảnh chụp trong app, có dấu thời gian</string>
    <string name="specs">Thông tin máy</string>
    <string name="more_text">Xem thêm</string>
    <string name="less_text">Thu gọn</string>
    <string name="deal">Giao dịch</string>
    <string name="path_meet">Gặp mặt</string>
    <string name="path_cod">COD, xem hàng trước</string>
    <string name="similar">Tin tương tự</string>
    <string name="message">Nhắn tin</string>
    <string name="make_offer">Trả giá</string>
    <string name="offered">Đã trả %1$s</string>
    <string name="offer_context">Giá đăng %1$s</string>
    <string name="offer_context_counter">Giá đăng %1$s · Người bán đề nghị %2$s</string>
    <string name="offer_note">Lời nhắn (không bắt buộc)</string>
    <string name="offer_send">Gửi %1$s</string>
    <string name="offer_reply_window">Người bán có 24 giờ để trả lời</string>
    <string name="offer_sent">Đã gửi đề nghị %1$s</string>
    <string name="question_sent">Đã gửi: “%1$s”</string>
    <string name="price_sheet">Giá tham khảo</string>
    <string name="price_range">%1$s – %2$s tr ₫</string>
    <string name="price_median">Giá giữa %1$s</string>
    <string name="price_method">%1$d tin tương tự trong %2$d ngày ở %3$s. Tính cả tình trạng, dung lượng và phiên bản.</string>
    <string name="sample_data">Số liệu mẫu của bản thử.</string>
    <string name="missing_listing">Bản thử chỉ có dữ liệu cho iPhone 13 Pro. Tin này mở được từ giai đoạn 2.</string>
    <string name="detail_failed">Chưa tải được tin này.</string>
    <string name="seller">Người bán</string>
```

- [ ] **Step 2: Write the failing ViewModel test**

`ListingDetailViewModelTest.kt`:

```kotlin
package vn.shopnexus.feature.discover.detail

import androidx.lifecycle.SavedStateHandle
import app.cash.turbine.test
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.Test
import vn.shopnexus.core.data.fake.FailurePolicy
import vn.shopnexus.core.data.fake.FakeDealEngine
import vn.shopnexus.core.data.fake.FakeDealRepository
import vn.shopnexus.core.data.fake.FakeListingRepository
import vn.shopnexus.core.data.fake.FakeWorld
import vn.shopnexus.core.domain.OfferCheck
import vn.shopnexus.core.domain.VN_ZONE
import vn.shopnexus.core.model.DealId
import vn.shopnexus.core.model.Party
import vn.shopnexus.core.model.ThreadItem
import vn.shopnexus.core.model.Vnd
import vn.shopnexus.core.navigation.ChatRoute
import vn.shopnexus.core.navigation.ListingRoute
import vn.shopnexus.core.testing.MainDispatcherRule
import vn.shopnexus.core.testing.SchedulerClock

@OptIn(ExperimentalCoroutinesApi::class)
class ListingDetailViewModelTest {
    @get:Rule val main = MainDispatcherRule()
    private val world = FakeWorld()
    private val failures = FailurePolicy(latencyMillis = 0)
    private val saved = SavedStateHandle()

    private fun TestScope.viewModel(id: String = "p-iphone13", handle: SavedStateHandle = saved): ListingDetailViewModel {
        val clock = SchedulerClock(testScheduler)
        val deals = FakeDealRepository(world, failures, FakeDealEngine(VN_ZONE), clock) { _, _ -> }
        return ListingDetailViewModel(ListingRoute(id), FakeListingRepository(world, failures), deals, clock, handle).also { vm ->
            backgroundScope.launch { vm.state.collect {} }
        }
    }

    private fun ListingDetailViewModel.ready() = state.value.content as DetailContent.Ready
    private fun thread() = world.value.chats.getValue(DealId("d-kiet")).deal.thread

    @Test
    fun loadsTheListingWithItsAge() = runTest {
        val vm = viewModel()
        advanceUntilIdle()
        assertThat(vm.ready().detail.listing.title).startsWith("iPhone 13 Pro")
        assertThat(vm.ready().ageHours).isEqualTo(3)
    }

    @Test
    fun anUnknownListingIsMissing() = runTest {
        val vm = viewModel("l-1510557880182")
        advanceUntilIdle()
        assertThat(vm.state.value.content).isEqualTo(DetailContent.Missing)
    }

    @Test
    fun theOfferSheetStaysBelowTheCounterAndDropsChipsOutsideIt() = runTest {
        val vm = viewModel()
        advanceUntilIdle()
        vm.onEvent(DetailEvent.OpenOffer)
        val offer = vm.state.value.offer!!
        assertThat(offer.amount).isEqualTo(Vnd(10_500_000))
        assertThat(offer.range.ceiling).isEqualTo(Vnd(10_600_000))
        assertThat(offer.chips).containsExactly(Vnd(10_400_000), Vnd(10_000_000), Vnd(9_800_000)).inOrder()
    }

    @Test
    fun typedAmountsKeepOnlyDigits() = runTest {
        val vm = viewModel()
        advanceUntilIdle()
        vm.onEvent(DetailEvent.OpenOffer)
        vm.onEvent(DetailEvent.TypeOffer("10.300.000"))
        assertThat(vm.state.value.offer!!.check).isEqualTo(OfferCheck.Ok(Vnd(300_000)))
        vm.onEvent(DetailEvent.TypeOffer("10,3tr"))
        assertThat(vm.state.value.offer!!.check).isEqualTo(OfferCheck.TooLow(Vnd(5_500_000)))
        vm.onEvent(DetailEvent.TypeOffer(""))
        assertThat(vm.state.value.offer!!.check).isEqualTo(OfferCheck.Empty)
    }

    @Test
    fun sendingTwiceSendsOnceAndRelabelsTheButton() = runTest {
        failures.latencyMillis = 300
        val vm = viewModel()
        advanceUntilIdle()
        vm.onEvent(DetailEvent.OpenOffer)
        vm.navigation.test {
            vm.messages.test {
                vm.onEvent(DetailEvent.SendOffer)
                vm.onEvent(DetailEvent.SendOffer)
                assertThat(vm.state.value.offer!!.sending).isTrue()
                advanceUntilIdle()
                awaitItem().onAction!!.invoke()
            }
            assertThat(awaitItem()).isEqualTo(ChatRoute("d-kiet"))
        }
        assertThat(thread().count { it is ThreadItem.PriceMove && it.by == Party.BUYER && it.amount == Vnd(10_500_000) }).isEqualTo(1)
        assertThat(vm.state.value.offer).isNull()
        assertThat(vm.ready().detail.deal?.myOffer).isEqualTo(Vnd(10_500_000))
    }

    @Test
    fun aFailedOfferKeepsTheSheetOpen() = runTest {
        val vm = viewModel()
        advanceUntilIdle()
        vm.onEvent(DetailEvent.OpenOffer)
        failures.rate = 1.0
        vm.messages.test {
            vm.onEvent(DetailEvent.SendOffer)
            assertThat(awaitItem().text).isEqualTo(vn.shopnexus.core.designsystem.R.string.send_failed)
        }
        assertThat(vm.state.value.offer!!.sending).isFalse()
        assertThat(vm.ready().detail.deal?.myOffer).isNull()
    }

    @Test
    fun theDraftSurvivesRecreation() = runTest {
        val vm = viewModel()
        advanceUntilIdle()
        vm.onEvent(DetailEvent.OpenOffer)
        vm.onEvent(DetailEvent.StepOffer(up = false))
        vm.onEvent(DetailEvent.TypeNote("Lấy luôn nhé"))
        val again = viewModel(handle = saved)
        advanceUntilIdle()
        assertThat(again.state.value.offer!!.amount).isEqualTo(Vnd(10_400_000))
        assertThat(again.state.value.offer!!.note).isEqualTo("Lấy luôn nhé")
    }

    @Test
    fun aQuestionChipSendsTheFirstMessage() = runTest {
        val vm = viewModel()
        advanceUntilIdle()
        vm.onEvent(DetailEvent.Ask("Máy còn không bạn?"))
        advanceUntilIdle()
        assertThat(thread().last()).isInstanceOf(ThreadItem.Text::class.java)
        assertThat((thread().last() as ThreadItem.Text).text).isEqualTo("Máy còn không bạn?")
    }

    @Test
    fun hidingSimilarOffersUndo() = runTest {
        val vm = viewModel()
        advanceUntilIdle()
        vm.messages.test {
            vm.onEvent(DetailEvent.HideSimilar)
            assertThat(vm.state.value.similarHidden).isTrue()
            awaitItem().onAction!!.invoke()
        }
        assertThat(vm.state.value.similarHidden).isFalse()
    }
}
```

Run: `./gradlew :feature:discover:testDebugUnitTest --tests "*ListingDetailViewModelTest*"`
Expected: FAIL, `Unresolved reference 'ListingDetailViewModel'`.

- [ ] **Step 3: Write the ViewModel**

`detail/ListingDetailViewModel.kt`:

```kotlin
package vn.shopnexus.feature.discover.detail

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.navigation3.runtime.NavKey
import dagger.assisted.Assisted
import dagger.assisted.AssistedFactory
import dagger.assisted.AssistedInject
import dagger.hilt.android.lifecycle.HiltViewModel
import java.time.Clock
import java.time.Duration
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import vn.shopnexus.core.data.DealRepository
import vn.shopnexus.core.data.ListingRepository
import vn.shopnexus.core.designsystem.component.UiMessage
import vn.shopnexus.core.domain.OfferCheck
import vn.shopnexus.core.domain.OfferRange
import vn.shopnexus.core.domain.offerRange
import vn.shopnexus.core.domain.parseOfferInput
import vn.shopnexus.core.model.DealCommand
import vn.shopnexus.core.model.ListingDetail
import vn.shopnexus.core.model.ListingId
import vn.shopnexus.core.model.ReportReason
import vn.shopnexus.core.model.Vnd
import vn.shopnexus.core.model.full
import vn.shopnexus.core.navigation.ChatRoute
import vn.shopnexus.core.navigation.ListingRoute
import vn.shopnexus.core.navigation.PlaceholderRoute
import vn.shopnexus.feature.discover.R
import vn.shopnexus.core.designsystem.R as DesignR

sealed interface DetailContent {
    data object Loading : DetailContent
    data object Failed : DetailContent
    data object Missing : DetailContent
    data class Ready(val detail: ListingDetail, val ageHours: Long) : DetailContent
}

data class OfferSheetState(
    val amount: Vnd?,
    val note: String,
    val range: OfferRange,
    val check: OfferCheck,
    val chips: List<Vnd>,
    val sending: Boolean,
)

data class DetailUiState(
    val content: DetailContent = DetailContent.Loading,
    val offer: OfferSheetState? = null,
    val similarHidden: Boolean = false,
)

sealed interface DetailEvent {
    data object Retry : DetailEvent
    data object ToggleSave : DetailEvent
    data object OpenOffer : DetailEvent
    data class StepOffer(val up: Boolean) : DetailEvent
    data class PickOffer(val amount: Vnd) : DetailEvent
    data class TypeOffer(val text: String) : DetailEvent
    data class TypeNote(val text: String) : DetailEvent
    data object CloseOffer : DetailEvent
    data object SendOffer : DetailEvent
    data class Ask(val question: String) : DetailEvent
    data object HideSimilar : DetailEvent
    data class Report(val reason: ReportReason) : DetailEvent
}

private const val OPEN = "offer.open"
private const val AMOUNT = "offer.amount"
private const val NOTE = "offer.note"
private const val NONE = -1L

@OptIn(ExperimentalCoroutinesApi::class)
@HiltViewModel(assistedFactory = ListingDetailViewModel.Factory::class)
class ListingDetailViewModel @AssistedInject constructor(
    @Assisted private val route: ListingRoute,
    private val listings: ListingRepository,
    private val deals: DealRepository,
    private val clock: Clock,
    private val saved: SavedStateHandle,
) : ViewModel() {
    @AssistedFactory
    interface Factory {
        fun create(route: ListingRoute): ListingDetailViewModel
    }

    private val id = ListingId(route.id)
    private val attempt = MutableStateFlow(0)
    private val sending = MutableStateFlow(false)
    private val pendingSave = MutableStateFlow<Boolean?>(null)
    private val similarHidden = MutableStateFlow(false)
    private val outbox = Channel<UiMessage>(Channel.BUFFERED)
    private val routes = Channel<NavKey>(Channel.BUFFERED)
    val messages: Flow<UiMessage> = outbox.receiveAsFlow()
    val navigation: Flow<NavKey> = routes.receiveAsFlow()

    private val content: StateFlow<DetailContent> = attempt.flatMapLatest {
        listings.detail(id)
            .map<ListingDetail?, DetailContent> { d ->
                if (d == null) DetailContent.Missing
                else DetailContent.Ready(d, Duration.between(d.listing.postedAt, clock.instant()).toHours())
            }
            .onStart { emit(DetailContent.Loading) }
            .catch { emit(DetailContent.Failed) }
    }.stateIn(viewModelScope, SharingStarted.Eagerly, DetailContent.Loading)

    private val draft = combine(
        saved.getStateFlow(OPEN, false),
        saved.getStateFlow(AMOUNT, NONE),
        saved.getStateFlow(NOTE, ""),
    ) { open, amount, note -> Triple(open, amount.takeIf { it != NONE }?.let(::Vnd), note) }

    val state: StateFlow<DetailUiState> = combine(content, draft, sending, pendingSave, similarHidden) { c, (open, amount, note), busy, save, hidden ->
        val shown = if (c is DetailContent.Ready && save != null) c.copy(detail = c.detail.copy(saved = save)) else c
        val offer = (c as? DetailContent.Ready)?.takeIf { open }?.let { ready ->
            val range = ready.detail.range()
            OfferSheetState(amount, note, range, range.check(amount), ready.detail.suggestedOffers.filter { range.check(it) is OfferCheck.Ok }, busy)
        }
        DetailUiState(shown, offer, hidden)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), DetailUiState())

    private fun ListingDetail.range(): OfferRange = offerRange(listing.price, deal?.counter)
    private fun ready(): DetailContent.Ready? = content.value as? DetailContent.Ready
    private fun setAmount(amount: Vnd?) { saved[AMOUNT] = amount?.amount ?: NONE }

    fun onEvent(event: DetailEvent) {
        val ready = ready()
        when (event) {
            DetailEvent.Retry -> attempt.update { it + 1 }
            DetailEvent.ToggleSave -> ready?.let { toggleSave(it.detail) }
            DetailEvent.OpenOffer -> ready?.detail?.let { d ->
                if (d.deal?.myOffer != null) { routes.trySend(ChatRoute(d.deal.id.value)); return }
                if (saved.get<Long>(AMOUNT) == null || saved.get<Long>(AMOUNT) == NONE) {
                    setAmount(d.range().stepped(d.deal?.counter ?: d.listing.price, up = false))
                }
                saved[OPEN] = true
            }
            is DetailEvent.StepOffer -> ready?.detail?.range()?.let { r ->
                setAmount(r.stepped(saved.get<Long>(AMOUNT)?.takeIf { it != NONE }?.let(::Vnd) ?: r.highest, event.up))
            }
            is DetailEvent.PickOffer -> setAmount(event.amount)
            is DetailEvent.TypeOffer -> setAmount(parseOfferInput(event.text))
            is DetailEvent.TypeNote -> saved[NOTE] = event.text.take(200)
            DetailEvent.CloseOffer -> closeOffer()
            DetailEvent.SendOffer -> ready?.let { sendOffer(it.detail) }
            is DetailEvent.Ask -> ready?.let { ask(it.detail, event.question) }
            DetailEvent.HideSimilar -> {
                similarHidden.value = true
                outbox.trySend(UiMessage(R.string.similar_hidden, action = DesignR.string.undo) { similarHidden.value = false })
            }
            is DetailEvent.Report -> viewModelScope.launch {
                listings.report(id, event.reason)
                    .onSuccess { outbox.send(UiMessage(R.string.report_sent)) }
                    .onFailure { outbox.send(UiMessage(DesignR.string.send_failed)) }
            }
        }
    }

    private fun closeOffer() {
        saved[OPEN] = false
        saved[AMOUNT] = NONE
        saved[NOTE] = ""
    }

    private fun toggleSave(detail: ListingDetail) {
        val target = !(pendingSave.value ?: detail.saved)
        pendingSave.value = target
        viewModelScope.launch {
            val result = listings.setSaved(id, target)
            pendingSave.value = null
            result.onFailure { outbox.send(UiMessage(DesignR.string.save_failed)) }
        }
    }

    /** One command at a time: a second tap while the first is in flight does nothing. */
    private fun sendOffer(detail: ListingDetail) {
        val deal = detail.deal ?: run { routes.trySend(PlaceholderRoute(3, "Trả giá")); return }
        val amount = saved.get<Long>(AMOUNT)?.takeIf { it != NONE }?.let(::Vnd) ?: return
        if (sending.value || detail.range().check(amount) !is OfferCheck.Ok) return
        val note = saved.get<String>(NOTE).orEmpty().trim().ifEmpty { null }
        sending.value = true
        viewModelScope.launch {
            deals.send(deal.id, DealCommand.SendOffer(amount, note))
                .onSuccess {
                    closeOffer()
                    outbox.send(UiMessage(R.string.offer_sent, listOf(amount.full()), DesignR.string.view) { routes.trySend(ChatRoute(deal.id.value)) })
                }
                .onFailure { outbox.send(UiMessage(DesignR.string.send_failed)) }
            sending.value = false
        }
    }

    private fun ask(detail: ListingDetail, question: String) {
        val deal = detail.deal ?: run { routes.trySend(PlaceholderRoute(3, "Tin nhắn")); return }
        viewModelScope.launch {
            deals.send(deal.id, DealCommand.SendText(question))
                .onSuccess { outbox.send(UiMessage(R.string.question_sent, listOf(question), DesignR.string.view) { routes.trySend(ChatRoute(deal.id.value)) }) }
                .onFailure { outbox.send(UiMessage(DesignR.string.send_failed)) }
        }
    }
}
```

`content` starts eagerly so that `ready()` sees the listing as soon as it loads; `state` adds the sheet and the local flags on top.

Run: `./gradlew :feature:discover:testDebugUnitTest --tests "*ListingDetailViewModelTest*"`
Expected: PASS, 9 tests.

- [ ] **Step 4: Add the all-windows capture to the harness**

Append to `core/testing/.../Screenshots.kt`:

```kotlin
/** Sheets, dialogs and popups live in their own windows; this captures every window on screen. */
@OptIn(com.github.takahirom.roborazzi.ExperimentalRoborazziApi::class)
fun captureAllWindows(name: String, variant: Variant = Variant.LIGHT) {
    com.github.takahirom.roborazzi.captureScreenRoboImage("src/test/screenshots/$name-${variant.suffix}.png", roborazziOptions = options)
}
```

- [ ] **Step 5: Write the failing screen test**

`ListingDetailScreenTest.kt`:

```kotlin
package vn.shopnexus.feature.discover.detail

import androidx.compose.material3.SnackbarHostState
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.onNodeWithTag
import androidx.navigation3.runtime.NavKey
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import vn.shopnexus.core.data.fake.Fixtures
import vn.shopnexus.core.domain.OfferCheck
import vn.shopnexus.core.domain.offerRange
import vn.shopnexus.core.model.Vnd
import vn.shopnexus.core.navigation.PlaceholderRoute
import vn.shopnexus.core.testing.Variant
import vn.shopnexus.core.testing.VariantFrame
import vn.shopnexus.core.testing.assertNoClippedText
import vn.shopnexus.core.testing.captureAllWindows
import vn.shopnexus.core.testing.captureVariants
import vn.shopnexus.core.testing.fakeImages

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w412dp-h915dp-xhdpi")
class ListingDetailScreenTest {
    @get:Rule val compose = createComposeRule()
    private val detail = Fixtures.detail("p-iphone13")
    private val ready = DetailUiState(DetailContent.Ready(detail, ageHours = 3))
    private val events = mutableListOf<DetailEvent>()
    private val pushed = mutableListOf<NavKey>()

    private fun show(state: DetailUiState, variant: Variant = Variant.LIGHT) {
        fakeImages()
        compose.setContent { VariantFrame(variant) { ListingDetailScreen(state, { events += it }, { pushed += it }, {}, SnackbarHostState()) } }
    }

    @Test
    fun theDealSectionDimsCodAndCarriesTheMoneySentences() {
        show(ready)
        compose.onNodeWithTag("detail-list").performScrollToNode(hasText("Món trên 5 triệu chỉ giao dịch gặp mặt."))
        compose.onNodeWithText("Gặp mặt không có bảo vệ tiền. Kiểm theo danh sách rồi mới trả.").assertExists()
        compose.onNodeWithText("ShopNexus không giữ tiền và không nhận cọc.").assertExists()
        compose.onNodeWithContentDescription("COD, xem hàng trước, Món trên 5 triệu chỉ giao dịch gặp mặt.").assertExists()
    }

    @Test
    fun theDockedBarOffersAndTheSellerRowOpensAPlaceholder() {
        show(ready)
        compose.onNodeWithText("Trả giá").performClick()
        compose.onNodeWithText("Tuấn Kiệt").performClick()
        assertThat(events).contains(DetailEvent.OpenOffer)
        assertThat(pushed).contains(PlaceholderRoute(2, "Người bán"))
    }

    @Test
    fun anOpenOfferRelabelsTheMainButton() {
        show(DetailUiState(DetailContent.Ready(detail.copy(deal = detail.deal!!.copy(myOffer = Vnd(10_400_000))), 3)))
        compose.onNodeWithText("Đã trả 10,4 tr").assertExists()
    }

    @Test
    fun anOfferAtTheCounterCannotBeSent() {
        val range = offerRange(detail.listing.price, Vnd(10_600_000))
        show(ready.copy(offer = OfferSheetState(Vnd(10_600_000), "", range, OfferCheck.NotBelow(Vnd(10_600_000)), emptyList(), false)))
        compose.onNodeWithText("Thấp hơn 10.600.000\u00A0₫. Bằng giá này thì bấm Đồng ý.").assertExists()
        compose.onNodeWithText("Gửi", substring = true).assertIsNotEnabled()
    }

    @Test
    fun aMissingListingSaysSo() {
        show(DetailUiState(DetailContent.Missing))
        compose.onNodeWithText("Bản thử chỉ có dữ liệu cho iPhone 13 Pro. Tin này mở được từ giai đoạn 2.").assertExists()
    }

    @Test
    fun textFitsAtFontScale130() {
        show(ready, Variant.FONT_130)
        compose.assertNoClippedText()
    }

    @Test
    fun screenshots() = compose.captureVariants("detail") { ListingDetailScreen(ready, {}, {}, {}, SnackbarHostState()) }

    @Test
    fun offerSheetScreenshot() {
        val range = offerRange(detail.listing.price, Vnd(10_600_000))
        show(ready.copy(offer = OfferSheetState(Vnd(10_500_000), "", range, OfferCheck.Ok(Vnd(100_000)), listOf(Vnd(10_400_000), Vnd(10_000_000), Vnd(9_800_000)), false)))
        compose.waitForIdle()
        captureAllWindows("detail-offer")
    }
}
```

The money-sentence and COD texts use the shared strings from Task 15, so this test also checks that Listing detail uses the same words as Chat. "COD, xem hàng trước, …" is the merged label `GroupRow` builds from its title and supporting text; `full()` puts a non-breaking space before ₫, so the expected text writes it as `\u00A0`.

Run: `./gradlew :feature:discover:testDebugUnitTest --tests "*ListingDetailScreenTest*"`
Expected: FAIL, `Unresolved reference 'ListingDetailScreen'`.

- [ ] **Step 6: Write the sections**

`detail/DetailSections.kt`:

```kotlin
package vn.shopnexus.feature.discover.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.gestures.snapping.SnapPosition
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import java.time.format.DateTimeFormatter
import vn.shopnexus.core.designsystem.component.ConditionScale
import vn.shopnexus.core.designsystem.component.DeclaredMarkRow
import vn.shopnexus.core.designsystem.component.Figure
import vn.shopnexus.core.designsystem.component.GroupRow
import vn.shopnexus.core.designsystem.component.GroupedList
import vn.shopnexus.core.designsystem.component.MoneyNote
import vn.shopnexus.core.designsystem.component.SaveToggle
import vn.shopnexus.core.designsystem.component.SparkleLabel
import vn.shopnexus.core.designsystem.component.TierChip
import vn.shopnexus.core.designsystem.component.conditionLabel
import vn.shopnexus.core.designsystem.component.distanceLabel
import vn.shopnexus.core.designsystem.component.moneyText
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.core.designsystem.theme.Corners
import vn.shopnexus.core.domain.MoneyStep
import vn.shopnexus.core.domain.VN_ZONE
import vn.shopnexus.core.domain.availablePaths
import vn.shopnexus.core.domain.moneyNotes
import vn.shopnexus.core.model.HandoverPath
import vn.shopnexus.core.model.ListingDetail
import vn.shopnexus.core.model.MoneyKey
import vn.shopnexus.core.model.PhotoSource
import vn.shopnexus.feature.discover.R

@Composable
internal fun SectionTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, style = MaterialTheme.typography.titleLarge, modifier = modifier.padding(start = 16.dp, end = 16.dp, top = 32.dp, bottom = 12.dp).semantics { heading() })
}

/** 346 dp squares with 28 dp corners, 8 dp apart, snapping to the start; the counter sits on the current photo. */
@Composable
internal fun PhotoRow(urls: List<String>, state: LazyListState, onOpen: (Int) -> Unit) {
    LazyRow(
        state = state,
        contentPadding = PaddingValues(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        flingBehavior = rememberSnapFlingBehavior(state, SnapPosition.Start),
    ) {
        itemsIndexed(urls) { i, url ->
            Box(Modifier.size(346.dp).clip(Corners.ExtraLarge).background(MaterialTheme.colorScheme.surfaceContainerHigh)) {
                AsyncImage(
                    url,
                    contentDescription = stringResource(R.string.open_photo, i + 1),
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.size(346.dp).clickable { onOpen(i) },
                )
                Text(
                    stringResource(R.string.photo_count, i + 1, urls.size),
                    style = MaterialTheme.typography.labelMedium,
                    color = Color.White,
                    modifier = Modifier.align(Alignment.BottomEnd).padding(12.dp)
                        .background(Color.Black.copy(alpha = 0.6f), CircleShape).padding(horizontal = 10.dp, vertical = 4.dp),
                )
            }
        }
    }
}

@Composable
internal fun ageText(hours: Long): String = when {
    hours < 1 -> stringResource(R.string.age_just_now)
    hours < 24 -> stringResource(R.string.age_hours, hours.toInt())
    else -> stringResource(R.string.age_days, (hours / 24).toInt())
}

/** Price with save, the AI price line, the title and three icon facts. */
@Composable
internal fun PriceBlock(detail: ListingDetail, ageHours: Long, onToggleSave: () -> Unit, onPriceSheet: () -> Unit) {
    val c = MaterialTheme.colorScheme
    val listing = detail.listing
    Column(Modifier.padding(horizontal = 16.dp).padding(top = 16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Figure(listing.price, Modifier.weight(1f))
            SaveToggle(detail.saved, onToggleSave)
        }
        detail.insight?.let { insight ->
            Row(
                Modifier.clip(CircleShape).clickable(onClick = onPriceSheet).padding(vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                SparkleLabel(stringResource(R.string.insight_detail, insight.percent), priceTalk = true)
                SymbolIcon(Symbol.ChevronRight, contentDescription = null, size = 18.dp, tint = c.tertiary)
            }
        }
        Text(listing.title, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(top = 4.dp))
        Row(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Fact(Symbol.Check, conditionLabel(listing.condition))
            Fact(Symbol.LocationOn, distanceLabel(listing.distanceKm))
            Fact(Symbol.Schedule, ageText(ageHours))
        }
    }
}

@Composable
private fun Fact(icon: Symbol, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        SymbolIcon(icon, contentDescription = null, size = 16.dp, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** The seller as Google Play shows a developer: avatar, name, tier, then a scrolling row of stats split by rules. */
@Composable
internal fun SellerRow(detail: ListingDetail, onOpen: () -> Unit) {
    val s = detail.seller
    val c = MaterialTheme.colorScheme
    Column(Modifier.padding(top = 24.dp)) {
        Row(
            Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            AsyncImage(s.avatarUrl, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.size(40.dp).clip(CircleShape).background(c.secondaryContainer))
            Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(s.name, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (s.verified) SymbolIcon(Symbol.Verified, stringResource(R.string.verified), filled = true, size = 18.dp, tint = c.primary)
            }
            TierChip(s.tier)
        }
        Row(
            Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp).height(40.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Stat(stringResource(R.string.rating_count, "%.1f ★".format(s.rating).replace('.', ','), s.ratingCount))
            VerticalDivider(Modifier.height(24.dp), color = c.outlineVariant)
            Stat(stringResource(R.string.sold, s.sold))
            VerticalDivider(Modifier.height(24.dp), color = c.outlineVariant)
            Stat(stringResource(R.string.reply_time, s.replyTime))
            VerticalDivider(Modifier.height(24.dp), color = c.outlineVariant)
            Stat(stringResource(R.string.joined, s.joinedYear))
        }
    }
}

@Composable
private fun Stat(text: String) = Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)

/** Chips that send a first message to the seller. */
@Composable
internal fun QuestionChips(questions: List<String>, onAsk: (String) -> Unit) {
    LazyRow(Modifier.padding(top = 8.dp), contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        itemsIndexed(questions) { _, q ->
            AssistChip(
                onClick = { onAsk(q) },
                label = { Text(q) },
                leadingIcon = { SymbolIcon(Symbol.Chat, contentDescription = null, size = AssistChipDefaults.IconSize) },
                shape = CircleShape,
            )
        }
    }
}

private val DAY = DateTimeFormatter.ofPattern("dd/MM").withZone(VN_ZONE)

/** The condition scale, the declared marks with their close-ups, where the photos came from, and the sentence on marks. */
@Composable
internal fun ConditionSection(detail: ListingDetail, onOpenMark: (Int) -> Unit) {
    val listing = detail.listing
    val inApp = listing.photos.count { it.source == PhotoSource.APP }
    Column {
        SectionTitle(stringResource(R.string.condition))
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            ConditionScale(listing.condition)
            if (listing.declaredMarks.isNotEmpty()) {
                Text(stringResource(R.string.declared), style = MaterialTheme.typography.titleSmall)
                listing.declaredMarks.forEachIndexed { i, mark ->
                    val day = mark.closeUp.capturedAt?.let(DAY::format).orEmpty()
                    DeclaredMarkRow(mark, stringResource(R.string.close_up_captured, day), onOpen = { onOpenMark(i) })
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                SymbolIcon(Symbol.PhotoCamera, contentDescription = null, size = 18.dp, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(
                    if (inApp == listing.photos.size) stringResource(R.string.all_photos_in_app, inApp)
                    else stringResource(R.string.some_photos_in_app, inApp, listing.photos.size),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            moneyNotes(MoneyStep.LISTING_CONDITION, listing.price).forEach { MoneyNote(it) }
        }
    }
}

/** Two columns of specs, then the description clamped to four lines. */
@Composable
internal fun SpecsSection(detail: ListingDetail) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    Column {
        SectionTitle(stringResource(R.string.specs))
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            detail.listing.specs.chunked(2).forEach { pair ->
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    pair.forEach { spec ->
                        Column(Modifier.weight(1f)) {
                            Text(spec.label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(spec.value, style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                    if (pair.size == 1) Box(Modifier.weight(1f))
                }
            }
            Text(
                detail.listing.description,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = if (expanded) Int.MAX_VALUE else 4,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 8.dp),
            )
            TextButton(onClick = { expanded = !expanded }, modifier = Modifier.padding(start = 0.dp)) {
                Text(stringResource(if (expanded) R.string.less_text else R.string.more_text))
            }
        }
    }
}

/** The two ways to hand over as grouped rows; COD is dimmed above 5 triệu. Then the money sentences of this step. */
@Composable
internal fun DealSection(detail: ListingDetail) {
    val listing = detail.listing
    val open = availablePaths(listing.paths, listing.price)
    Column {
        SectionTitle(stringResource(R.string.deal))
        GroupedList(Modifier.padding(horizontal = 16.dp)) {
            row("meet") {
                GroupRow(stringResource(R.string.path_meet), supporting = listing.meetNote, leading = Symbol.Handshake, enabled = HandoverPath.MEET in open)
            }
            row("cod") {
                val codOpen = HandoverPath.COD in open
                GroupRow(
                    stringResource(R.string.path_cod),
                    supporting = if (codOpen) null else moneyText(MoneyKey.OVER_LIMIT),
                    leading = if (codOpen) Symbol.LocalShipping else Symbol.Block,
                    enabled = codOpen,
                    trailing = { Switch(checked = codOpen, onCheckedChange = null, enabled = false) },
                )
            }
        }
        Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            moneyNotes(MoneyStep.LISTING_PATHS, listing.price).forEach { MoneyNote(it) }
        }
    }
}
```

- [ ] **Step 7: Write the sheets and the photo viewer**

`detail/DetailSheets.kt`:

```kotlin
package vn.shopnexus.feature.discover.detail

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.background
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import vn.shopnexus.core.designsystem.component.AmountStepper
import vn.shopnexus.core.designsystem.component.FullWidthSheet
import vn.shopnexus.core.designsystem.component.SparkleLabel
import vn.shopnexus.core.designsystem.component.offerCheckText
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.core.designsystem.theme.ShopNexusTheme
import vn.shopnexus.core.domain.OfferCheck
import vn.shopnexus.core.model.ListingDetail
import vn.shopnexus.core.model.PriceInsight
import vn.shopnexus.core.model.ReportReason
import vn.shopnexus.core.model.full
import vn.shopnexus.core.model.short
import vn.shopnexus.feature.discover.R

/** The first offer: the amount control, the gap line, chips, an optional note, and "Gửi" in terracotta. */
@Composable
internal fun OfferSheet(detail: ListingDetail, offer: OfferSheetState, onEvent: (DetailEvent) -> Unit) {
    val c = MaterialTheme.colorScheme
    val counter = detail.deal?.counter
    val noteLabel = stringResource(R.string.offer_note)
    FullWidthSheet(onDismiss = { onEvent(DetailEvent.CloseOffer) }, title = stringResource(R.string.make_offer)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            SymbolIcon(Symbol.Sell, contentDescription = null, size = 16.dp, tint = c.onSurfaceVariant)
            Text(
                if (counter != null) stringResource(R.string.offer_context_counter, detail.listing.price.full(), counter.full())
                else stringResource(R.string.offer_context, detail.listing.price.full()),
                style = MaterialTheme.typography.bodyMedium,
                color = c.onSurfaceVariant,
            )
        }
        AmountStepper(
            amount = offer.amount,
            range = offer.range,
            onStep = { onEvent(DetailEvent.StepOffer(it)) },
            onType = { onEvent(DetailEvent.TypeOffer(it)) },
            modifier = Modifier.padding(top = 24.dp),
        )
        Text(
            offerCheckText(offer.check),
            style = MaterialTheme.typography.bodySmall,
            color = if (offer.check is OfferCheck.Ok) c.onSurfaceVariant else c.error,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
        )
        LazyRow(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(horizontal = 0.dp)) {
            items(offer.chips) { amount ->
                FilterChip(
                    selected = offer.amount == amount,
                    onClick = { onEvent(DetailEvent.PickOffer(amount)) },
                    label = { Text(amount.short()) },
                    shape = CircleShape,
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = ShopNexusTheme.extended.tertiaryFixed,
                        selectedLabelColor = ShopNexusTheme.extended.onTertiaryFixedVariant,
                    ),
                )
            }
        }
        BasicTextField(
            value = offer.note,
            onValueChange = { onEvent(DetailEvent.TypeNote(it)) },
            singleLine = true,
            textStyle = MaterialTheme.typography.bodyLarge.copy(color = c.onSurface),
            cursorBrush = SolidColor(c.primary),
            modifier = Modifier.padding(top = 24.dp).fillMaxWidth().height(48.dp).background(c.surfaceContainerHigh, CircleShape)
                .padding(horizontal = 20.dp).semantics { contentDescription = noteLabel },
            decorationBox = { inner ->
                Row(Modifier.fillMaxWidth().height(48.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (offer.note.isEmpty()) Text(stringResource(R.string.offer_note), style = MaterialTheme.typography.bodyLarge, color = c.onSurfaceVariant)
                    inner()
                }
            },
        )
        val ok = offer.check is OfferCheck.Ok
        Button(
            onClick = { onEvent(DetailEvent.SendOffer) },
            enabled = ok && !offer.sending,
            colors = ButtonDefaults.buttonColors(containerColor = c.tertiary, contentColor = c.onTertiary),
            modifier = Modifier.padding(top = 16.dp).fillMaxWidth().height(56.dp),
        ) {
            SymbolIcon(Symbol.Send, contentDescription = null, size = 20.dp)
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.offer_send, if (ok) offer.amount!!.short() else ""))
        }
        Row(Modifier.fillMaxWidth().padding(top = 12.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            SymbolIcon(Symbol.Timer, contentDescription = null, size = 16.dp, tint = c.onSurfaceVariant)
            Spacer(Modifier.width(4.dp))
            Text(stringResource(R.string.offer_reply_window), style = MaterialTheme.typography.bodySmall, color = c.onSurfaceVariant)
        }
    }
}

/** "Giá tham khảo": the range, the median it was compared with, how it was computed, and that the numbers are sample data. */
@Composable
internal fun PriceSheet(insight: PriceInsight, onDismiss: () -> Unit) {
    val c = MaterialTheme.colorScheme
    FullWidthSheet(onDismiss = onDismiss, title = stringResource(R.string.price_sheet)) {
        val range = insight.range ?: return@FullWidthSheet
        Text(
            stringResource(R.string.price_range, range.low.short().removeSuffix(" tr"), range.high.short().removeSuffix(" tr")),
            style = MaterialTheme.typography.headlineSmall,
        )
        Text(stringResource(R.string.price_median, range.median.full()), style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(top = 4.dp))
        SparkleLabel(stringResource(R.string.insight_detail, insight.percent), priceTalk = true, modifier = Modifier.padding(top = 12.dp))
        if (insight.sampleSize != null && insight.windowDays != null && insight.area != null) {
            Text(
                stringResource(R.string.price_method, insight.sampleSize!!, insight.windowDays!!, insight.area!!),
                style = MaterialTheme.typography.bodyMedium,
                color = c.onSurfaceVariant,
                modifier = Modifier.padding(top = 12.dp),
            )
        }
        Text(stringResource(R.string.sample_data), style = MaterialTheme.typography.bodySmall, color = c.onSurfaceVariant, modifier = Modifier.padding(top = 8.dp))
    }
}

/** Four reasons as radio rows; a person reviews banned goods, fakes and fraud. */
@Composable
internal fun ReportSheet(onSend: (ReportReason) -> Unit, onDismiss: () -> Unit) {
    var picked by rememberSaveable { mutableStateOf<ReportReason?>(null) }
    val reasons = listOf(
        ReportReason.BANNED to R.string.report_banned, ReportReason.FAKE to R.string.report_fake,
        ReportReason.SCAM to R.string.report_scam, ReportReason.OTHER to R.string.report_other,
    )
    FullWidthSheet(onDismiss = onDismiss, title = stringResource(R.string.report_listing)) {
        Column(Modifier.selectableGroup()) {
            reasons.forEach { (reason, label) ->
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 56.dp).selectable(picked == reason, role = Role.RadioButton) { picked = reason },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RadioButton(selected = picked == reason, onClick = null)
                    Text(stringResource(label), style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(start = 16.dp))
                }
            }
        }
        Text(stringResource(R.string.report_scope), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 8.dp))
        Button(onClick = { picked?.let(onSend) }, enabled = picked != null, modifier = Modifier.padding(top = 16.dp).fillMaxWidth().height(48.dp)) {
            Text(stringResource(R.string.report_send))
        }
    }
}
```

`detail/PhotoViewer.kt`:

```kotlin
package vn.shopnexus.feature.discover.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import coil3.compose.AsyncImage
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.feature.discover.R
import vn.shopnexus.core.designsystem.R as DesignR

/** A full-screen black viewer that swipes between the photos, then the declared close-ups. */
@Composable
internal fun PhotoViewer(urls: List<String>, start: Int, onDismiss: () -> Unit) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        val pager = rememberPagerState(initialPage = start) { urls.size }
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            HorizontalPager(pager, Modifier.fillMaxSize()) { page ->
                AsyncImage(urls[page], contentDescription = stringResource(R.string.open_photo, page + 1), contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
            }
            IconButton(onClick = onDismiss, modifier = Modifier.statusBarsPadding().padding(4.dp)) {
                SymbolIcon(Symbol.Close, stringResource(DesignR.string.close), tint = Color.White)
            }
            Text(
                stringResource(R.string.photo_count, pager.currentPage + 1, urls.size),
                style = MaterialTheme.typography.labelLarge,
                color = Color.White,
                modifier = Modifier.align(Alignment.BottomCenter).padding(32.dp),
            )
        }
    }
}
```

- [ ] **Step 8: Write the screen and register it**

`detail/ListingDetailScreen.kt`:

```kotlin
package vn.shopnexus.feature.discover.detail

import android.content.Intent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation3.runtime.NavKey
import vn.shopnexus.core.designsystem.component.DockedActionBar
import vn.shopnexus.core.designsystem.component.ErrorState
import vn.shopnexus.core.designsystem.component.ListingRail
import vn.shopnexus.core.designsystem.component.MessageEffect
import vn.shopnexus.core.designsystem.component.SectionHeader
import vn.shopnexus.core.designsystem.component.ShopNexusLoading
import vn.shopnexus.core.designsystem.component.ShopNexusTopBar
import vn.shopnexus.core.designsystem.component.debugTrigger
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.core.model.short
import vn.shopnexus.core.navigation.ChatRoute
import vn.shopnexus.core.navigation.ListingRoute
import vn.shopnexus.core.navigation.Navigator
import vn.shopnexus.core.navigation.PlaceholderRoute
import vn.shopnexus.feature.discover.R
import vn.shopnexus.core.designsystem.R as DesignR

@Composable
internal fun ListingDetailEntry(route: ListingRoute, navigator: Navigator) {
    val viewModel = hiltViewModel<ListingDetailViewModel, ListingDetailViewModel.Factory>(creationCallback = { it.create(route) })
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    MessageEffect(viewModel.messages, snackbar)
    LaunchedEffect(viewModel) { viewModel.navigation.collect(navigator::push) }
    ListingDetailScreen(state, viewModel::onEvent, navigator::push, navigator::back, snackbar)
}

@Composable
fun ListingDetailScreen(
    state: DetailUiState,
    onEvent: (DetailEvent) -> Unit,
    onNavigate: (NavKey) -> Unit,
    onBack: () -> Unit,
    snackbar: SnackbarHostState,
    modifier: Modifier = Modifier,
) {
    val ready = state.content as? DetailContent.Ready
    val list = rememberLazyListState()
    val photosGone by remember { derivedStateOf { list.firstVisibleItemIndex > 0 } }
    var menu by remember { mutableStateOf(false) }
    var priceSheet by rememberSaveable { mutableStateOf(false) }
    var reportSheet by rememberSaveable { mutableStateOf(false) }
    var viewerAt by rememberSaveable { mutableIntStateOf(-1) }
    val context = LocalContext.current
    Scaffold(
        modifier = modifier,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            ShopNexusTopBar(
                title = {
                    AnimatedVisibility(ready != null && photosGone, enter = fadeIn(), exit = fadeOut()) {
                        Text(ready?.detail?.listing?.title.orEmpty(), style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.debugTrigger())
                    }
                },
                onBack = onBack,
                containerColor = if (photosGone) MaterialTheme.colorScheme.surfaceContainer else MaterialTheme.colorScheme.surface,
                actions = {
                    if (ready != null) {
                        IconButton(onClick = {
                            val l = ready.detail.listing
                            val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "${l.title}\nshopnexus://listing/${l.id.value}")
                            context.startActivity(Intent.createChooser(send, null))
                        }) { SymbolIcon(Symbol.Share, stringResource(R.string.share)) }
                        Box {
                            IconButton(onClick = { menu = true }) { SymbolIcon(Symbol.MoreVert, stringResource(R.string.more)) }
                            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.hide_similar)) },
                                    leadingIcon = { SymbolIcon(Symbol.VisibilityOff, null) },
                                    onClick = { menu = false; onEvent(DetailEvent.HideSimilar) },
                                )
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.report_listing)) },
                                    leadingIcon = { SymbolIcon(Symbol.Flag, null) },
                                    onClick = { menu = false; reportSheet = true },
                                )
                            }
                        }
                    }
                },
            )
        },
        bottomBar = { if (ready != null) DetailActions(ready, onEvent, onNavigate) },
    ) { padding ->
        when (val content = state.content) {
            DetailContent.Loading -> Box(Modifier.padding(padding).fillMaxSize(), Alignment.Center) { ShopNexusLoading() }
            DetailContent.Failed -> ErrorState(stringResource(R.string.detail_failed), { onEvent(DetailEvent.Retry) }, Modifier.padding(padding))
            DetailContent.Missing -> Column(
                Modifier.padding(padding).fillMaxSize().padding(24.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(stringResource(R.string.missing_listing), style = MaterialTheme.typography.bodyLarge, textAlign = TextAlign.Center, modifier = Modifier.padding(bottom = 16.dp))
                Button(onClick = onBack, modifier = Modifier.height(48.dp)) { Text(stringResource(DesignR.string.back)) }
            }
            is DetailContent.Ready -> {
                val detail = content.detail
                val photos = detail.listing.photos.map { it.url }
                val closeUps = detail.listing.declaredMarks.map { it.closeUp.url }
                val seller = stringResource(R.string.seller)
                val similarTitle = stringResource(R.string.similar)
                LazyColumn(Modifier.padding(padding).testTag("detail-list"), state = list, contentPadding = PaddingValues(bottom = 24.dp)) {
                    item(key = "photos") { PhotoRow(photos, rememberLazyListState()) { viewerAt = it } }
                    item(key = "price") { PriceBlock(detail, content.ageHours, { onEvent(DetailEvent.ToggleSave) }, { priceSheet = true }) }
                    item(key = "seller") { SellerRow(detail) { onNavigate(PlaceholderRoute(2, seller)) } }
                    item(key = "questions") { QuestionChips(detail.questions) { onEvent(DetailEvent.Ask(it)) } }
                    item(key = "condition") { ConditionSection(detail) { viewerAt = photos.size + it } }
                    item(key = "specs") { SpecsSection(detail) }
                    item(key = "deal") { DealSection(detail) }
                    if (!state.similarHidden && detail.similar.isNotEmpty()) {
                        item(key = "similar-title") { SectionHeader(similarTitle, onSeeAll = { onNavigate(PlaceholderRoute(2, similarTitle)) }) }
                        item(key = "similar") { ListingRail(detail.similar, { onNavigate(ListingRoute(it.id.value)) }, {}, showSave = false) }
                    }
                }
                state.offer?.let { OfferSheet(detail, it, onEvent) }
                if (priceSheet) detail.insight?.let { PriceSheet(it) { priceSheet = false } }
                if (reportSheet) ReportSheet(onSend = { reportSheet = false; onEvent(DetailEvent.Report(it)) }, onDismiss = { reportSheet = false })
                if (viewerAt >= 0) PhotoViewer(photos + closeUps, viewerAt) { viewerAt = -1 }
            }
        }
    }
}

/** "Nhắn tin" (tonal) and "Trả giá" in terracotta; with an open offer the main button reads "Đã trả 10,4 tr" and opens the chat. */
@Composable
private fun DetailActions(ready: DetailContent.Ready, onEvent: (DetailEvent) -> Unit, onNavigate: (NavKey) -> Unit) {
    val deal = ready.detail.deal
    val c = MaterialTheme.colorScheme
    DockedActionBar {
        FilledTonalButton(
            onClick = { onNavigate(deal?.let { ChatRoute(it.id.value) } ?: PlaceholderRoute(3, "Tin nhắn")) },
            modifier = Modifier.weight(1f).height(48.dp),
        ) { Text(stringResource(R.string.message)) }
        Button(
            onClick = { onEvent(DetailEvent.OpenOffer) },
            colors = ButtonDefaults.buttonColors(containerColor = c.tertiary, contentColor = c.onTertiary),
            modifier = Modifier.weight(1f).height(48.dp),
        ) {
            Text(deal?.myOffer?.let { stringResource(R.string.offered, it.short()) } ?: stringResource(R.string.make_offer), maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}
```

The similar rail shows no hearts: saving from it belongs to Đã lưu in stage 2.

Change `DiscoverInstaller.install` to:

```kotlin
    override fun install(scope: EntryProviderScope<NavKey>, navigator: Navigator) = with(scope) {
        entry<HomeRoute> { HomeEntry(navigator) }
        entry<ListingRoute> { route -> ListingDetailEntry(route, navigator) }
    }
```

with `import vn.shopnexus.core.navigation.ListingRoute` and `import vn.shopnexus.feature.discover.detail.ListingDetailEntry`.

- [ ] **Step 9: Run the tests and record the screenshots**

Run: `./gradlew :feature:discover:testDebugUnitTest`
Expected: PASS, 30 tests.

Run: `./gradlew :feature:discover:recordRoborazziDebug` and compare `detail-light.png` and `detail-offer-light.png` with `tmp/detail.html`: the 346 dp photo with "1/4"; the light 36 sp price with the smaller ₫ and the heart; "Rẻ hơn 13% so với tin tương tự" in terracotta with the chevron; the title and three facts; the seller with the verified icon and "Xuất sắc"; the question chips; the sheet with "Giá đăng 10.900.000 ₫ · Người bán đề nghị 10.600.000 ₫", the stepper at 10.500.000, "−100.000 ₫", three chips, the note pill, "Gửi 10,5 tr" in terracotta and the 24-hour line. Then `./gradlew :feature:discover:verifyRoborazziDebug`.

- [ ] **Step 10: Walk Listing detail on the emulator**

`./gradlew :app:installDebug`, open the iPhone 13 Pro card. Check: the bar takes `surfaceContainer` and the title once the photos scroll away; a photo opens the viewer and swipes; the declared mark opens its close-up; "Xem thêm" expands; the price line opens "Giá tham khảo"; "Trả giá" opens the sheet at 10,5 tr and "+" is disabled; typing "10.700.000" disables "Gửi" and the line says to accept instead; sending shows "Đã gửi đề nghị 10.500.000 ₫" with "Xem" and the main button reads "Đã trả 10,5 tr"; rotating the phone with the sheet open keeps the amount; a question chip shows its snackbar; "Báo cáo tin" sends after a reason is picked; share opens the Android share sheet. Open any other card: the missing-listing screen with "Quay lại".

- [ ] **Step 11: Commit**

```bash
git add core/testing feature/discover
git commit -m "feat(discover): add Listing detail with the offer, price and report sheets

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```


---

### Task 21: Chat ViewModel

The deal in one ViewModel: the console state from `DealConsole`, one command at a time, the unsent offer kept across recreation, optimistic checks and price pills that roll back on failure, the scanner, the composer and the incident record.

**Files:**
- Modify: `app2/settings.gradle.kts` (add `include(":feature:deal")`), `app2/app/build.gradle.kts` (add `implementation(project(":feature:deal"))`)
- Create: `app2/feature/deal/build.gradle.kts`, `app2/feature/deal/src/main/res/values/strings.xml`, `app2/feature/deal/src/test/resources/robolectric.properties` (`sdk=36`)
- Create in `app2/feature/deal/src/main/kotlin/vn/shopnexus/feature/deal/chat/`: `ChatUiState.kt`, `ChatViewModel.kt`
- Test: `app2/feature/deal/src/test/kotlin/vn/shopnexus/feature/deal/chat/ChatViewModelTest.kt`

**Interfaces:**
- Consumes: `DealRepository`, `QrScanner`, the fakes and `Simulator` (Tasks 10–12); `DealConsole`, `ConsoleState`, `ConsoleEvent`, `ConsoleDraft`, `offerRange`, `moneyNotes`, `meetingLabel`, `todayAt` (Tasks 5, 8, 9, 10); `UiMessage` (Task 19).
- Produces:
  ```kotlin
  sealed interface ChatContent { Loading; Failed; Missing; data class Ready(val view: ChatView) }
  data class OfferChip(val amount: Vnd, val middle: Boolean)
  data class TimeOption(val at: Instant, val label: String)
  data class RecordDraft(val photo: String?, val text: String) { val canSend: Boolean }
  data class ChatUiState(content, console: ConsoleState?, phase: Int, offerChips, meetingText: String?, counterHoursLeft: Long?,
      pending: Boolean, optimisticOffer: Vnd?, typing: Boolean, composer: String, scanning: Boolean, record: RecordDraft?,
      timeOptions: List<TimeOption>, moneyNotes: List<MoneyKey>)
  data class ChatLocal(pending, optimisticOffer, scanning, composer, record, checkOverrides: Map<String, Boolean>)
  internal fun chatUiState(content: ChatContent, draft: ConsoleDraft, local: ChatLocal, typing: Boolean, now: Instant, zone: ZoneId): ChatUiState
  sealed interface ChatEvent { Retry; Console(event: ConsoleEvent); Compose(text); SendMessage; Reply(text); StartScan; CancelScan;
      OpenRecord; CloseRecord; RecordPhoto(uri); RecordText(text); SendRecord; ConfirmRefund(id: RecordId) }
  class ChatViewModel : ViewModel { val state: StateFlow<ChatUiState>; val messages: Flow<UiMessage>; fun onEvent(e: ChatEvent)
      @AssistedFactory interface Factory { fun create(route: ChatRoute): ChatViewModel } }
  ```

- [ ] **Step 1: Create the module and its strings**

Add `include(":feature:deal")` to `settings.gradle.kts` and `implementation(project(":feature:deal"))` to `app/build.gradle.kts`.

`app2/feature/deal/build.gradle.kts`:

```kotlin
plugins {
    id("shopnexus.android.feature")
}

android {
    namespace = "vn.shopnexus.feature.deal"
}

dependencies {
    implementation(libs.androidx.activity.compose)
}
```

`app2/feature/deal/src/main/res/values/strings.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="chat_failed">Chưa tải được cuộc trò chuyện.</string>
    <string name="chat_missing">Bản thử chỉ có cuộc trò chuyện với Tuấn Kiệt.</string>
    <string name="open_listing">Xem tin %1$s</string>
    <string name="thread_opener">ShopNexus không giữ tiền và không nhận cọc.</string>
    <string name="typing">%1$s đang soạn tin</string>
    <string name="move_offer">%1$s trả giá %2$s</string>
    <string name="move_accept">%1$s đồng ý %2$s</string>
    <string name="you">Bạn</string>
    <string name="sending">Đang gửi</string>
    <string name="fold">Thu gọn</string>
    <string name="unfold">Mở rộng</string>
    <string name="counter_expires">%1$d giờ</string>
    <string name="make_offer">Trả giá</string>
    <string name="accept">Đồng ý</string>
    <string name="close_offer">Đóng trả giá</string>
    <string name="send_offer">Gửi %1$s</string>
    <string name="meet_middle">Gặp ở giữa</string>
    <string name="waiting_for">Chờ %1$s</string>
    <string name="withdraw">Rút lại</string>
    <string name="waiting_proposal">Chờ %1$s đề xuất giờ hẹn</string>
    <string name="change_meeting">Đổi giờ hẹn</string>
    <string name="confirm_meeting">Đồng ý hẹn</string>
    <string name="waiting_agree">Chờ %1$s đồng ý</string>
    <string name="check_items">Kiểm máy %1$d/%2$d</string>
    <string name="scan">Quét mã</string>
    <string name="rate_person">Đánh giá %1$s</string>
    <string name="stars">%1$d sao</string>
    <string name="problem">Máy có vấn đề?</string>
    <string name="done">Đã xong</string>
    <string name="message_hint">Nhắn tin</string>
    <string name="message_to">Nhắn tin cho %1$s</string>
    <string name="attach">Gửi ảnh</string>
    <string name="send">Gửi</string>
    <string name="schedule_title">Hẹn gặp</string>
    <string name="schedule_time">Giờ hẹn</string>
    <string name="schedule_place">Điểm hẹn gợi ý</string>
    <string name="schedule_send">Gửi đề xuất</string>
    <string name="checklist_title">Danh sách kiểm</string>
    <string name="checklist_declared">Đã khai trong tin</string>
    <string name="unchecked_title">Chưa kiểm xong</string>
    <string name="unchecked_text">Còn %1$d mục chưa kiểm. Đã trả tiền thì ShopNexus không đòi lại được.</string>
    <string name="unchecked_scan">Vẫn quét</string>
    <string name="unchecked_check">Kiểm tiếp</string>
    <string name="scanner_title">Quét mã trên máy %1$s</string>
    <string name="scanner_text">Quét khi đã kiểm hàng và trả tiền. Mã ghi nhận giao dịch đã diễn ra.</string>
    <string name="scanned">Đã đọc mã</string>
    <string name="scan_failed">Chưa đọc được mã. Thử lại</string>
    <string name="record_title">Ghi nhận sự cố</string>
    <string name="record_add_photo">Thêm ảnh</string>
    <string name="record_photo">Ảnh sự cố</string>
    <string name="record_what">Chuyện gì xảy ra</string>
    <string name="record_declared">Tin đã khai: %1$s.</string>
    <string name="record_who_decides">ShopNexus không phân xử. %1$s chọn tự hoàn tiền hoặc từ chối; từ chối thì ghi nhận hiện trên hồ sơ của họ.</string>
    <string name="record_send">Gửi ghi nhận</string>
    <string name="record_waiting">Chờ %1$s</string>
    <string name="record_refunded">%1$s tự hoàn %2$s</string>
    <string name="record_declined">%1$s từ chối</string>
    <string name="record_done">Đã xong</string>
    <string name="record_received">Đã nhận tiền hoàn</string>
    <string name="record_public">Vừa xong · Hiện cho cả hai bên</string>
    <string name="milestone_agreed">Chốt %1$s</string>
    <string name="milestone_agreed_line">Bắt tay rồi! Giờ hẹn gặp để xem máy nhé.</string>
    <string name="milestone_handed">Giao dịch đã ghi nhận</string>
    <string name="milestone_handed_line">Máy đã về tay bạn. Chúc bạn dùng thật vui!</string>
    <string name="milestone_rated">Cảm ơn bạn</string>
    <string name="milestone_rated_line">Đánh giá thật giúp chợ thêm tử tế.</string>
    <string-array name="quick_replies">
        <item>Xem máy trước được không?</item>
        <item>Ốp màu gì vậy bạn?</item>
        <item>Tối nay rảnh không?</item>
    </string-array>
</resources>
```

- [ ] **Step 2: Write the failing ViewModel test**

`ChatViewModelTest.kt`:

```kotlin
package vn.shopnexus.feature.deal.chat

import androidx.lifecycle.SavedStateHandle
import app.cash.turbine.test
import com.google.common.truth.Truth.assertThat
import java.time.Instant
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.Test
import vn.shopnexus.core.data.DealRepository
import vn.shopnexus.core.data.fake.FailurePolicy
import vn.shopnexus.core.data.fake.FakeDealEngine
import vn.shopnexus.core.data.fake.FakeDealRepository
import vn.shopnexus.core.data.fake.FakeQrScanner
import vn.shopnexus.core.data.fake.FakeWorld
import vn.shopnexus.core.data.fake.Simulator
import vn.shopnexus.core.domain.ConsoleEvent
import vn.shopnexus.core.domain.ConsoleState
import vn.shopnexus.core.domain.VN_ZONE
import vn.shopnexus.core.model.Deal
import vn.shopnexus.core.model.DealCommand
import vn.shopnexus.core.model.DealId
import vn.shopnexus.core.model.DealStage
import vn.shopnexus.core.model.MeetPoint
import vn.shopnexus.core.model.Meeting
import vn.shopnexus.core.model.MilestoneKind
import vn.shopnexus.core.model.MoneyKey
import vn.shopnexus.core.model.Party
import vn.shopnexus.core.model.PriceDirection
import vn.shopnexus.core.model.PriceInsight
import vn.shopnexus.core.model.RecordId
import vn.shopnexus.core.model.RecordStatus
import vn.shopnexus.core.model.ThreadItem
import vn.shopnexus.core.model.Vnd
import vn.shopnexus.core.navigation.ChatRoute
import vn.shopnexus.core.testing.MainDispatcherRule
import vn.shopnexus.core.testing.SchedulerClock
import vn.shopnexus.core.designsystem.R as DesignR

private class Recording(private val inner: DealRepository) : DealRepository by inner {
    val sent = mutableListOf<DealCommand>()
    override suspend fun send(id: DealId, command: DealCommand): Result<Deal> {
        sent += command
        return inner.send(id, command)
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelTest {
    @get:Rule val main = MainDispatcherRule()
    private val world = FakeWorld()
    private val failures = FailurePolicy(latencyMillis = 0)
    private val saved = SavedStateHandle()
    private val id = DealId("d-kiet")
    private lateinit var deals: Recording

    private fun TestScope.viewModel(handle: SavedStateHandle = saved): ChatViewModel {
        val clock = SchedulerClock(testScheduler)
        deals = Recording(FakeDealRepository(world, failures, FakeDealEngine(VN_ZONE), clock, Simulator(world, clock, backgroundScope, VN_ZONE)))
        return ChatViewModel(ChatRoute("d-kiet"), deals, FakeQrScanner(), clock, VN_ZONE, handle).also { vm ->
            backgroundScope.launch { vm.state.collect {} }
        }
    }

    private fun deal() = world.value.chats.getValue(id).deal
    private fun at(stage: DealStage, meeting: Meeting? = null) = world.update { s ->
        s.copy(chats = s.chats.mapValues { (_, v) -> v.copy(deal = v.deal.copy(stage = stage, agreedPrice = Vnd(10_600_000), meeting = meeting)) })
    }
    private val landmark = MeetPoint("Sảnh Landmark 81", "Có bảo vệ, đông người")
    private val tonight = Meeting(Instant.parse("2026-10-15T12:00:00Z"), landmark, Party.SELLER, confirmed = true)

    @Test
    fun showsTheCounterWithItsJudgmentAndTimeLeft() = runTest {
        val vm = viewModel()
        runCurrent()
        val s = vm.state.value
        assertThat(s.console).isEqualTo(ConsoleState.Countered(Vnd(10_600_000), PriceInsight(PriceDirection.CHEAPER, 15), Instant.parse("2026-10-16T07:10:00Z")))
        assertThat(s.counterHoursLeft).isEqualTo(23)
        assertThat(s.phase).isEqualTo(0)
    }

    @Test
    fun walksTheInPersonDealToTheEnd() = runTest {
        val vm = viewModel()
        runCurrent()
        vm.onEvent(ChatEvent.Console(ConsoleEvent.StartOffer))
        assertThat(vm.state.value.console).isInstanceOf(ConsoleState.Offering::class.java)
        assertThat(vm.state.value.offerChips).containsExactly(
            OfferChip(Vnd(10_500_000), middle = true), OfferChip(Vnd(10_400_000), false), OfferChip(Vnd(10_300_000), false),
        ).inOrder()
        vm.onEvent(ChatEvent.Console(ConsoleEvent.SendOffer))
        assertThat(vm.state.value.console).isEqualTo(ConsoleState.Waiting(Vnd(10_500_000)))

        advanceTimeBy(2_500); runCurrent()
        val agreed = vm.state.value
        assertThat(agreed.console).isInstanceOf(ConsoleState.Agreed::class.java)
        assertThat(agreed.meetingText).isEqualTo("19:00 hôm nay · Sảnh Landmark 81")
        assertThat(agreed.moneyNotes).containsExactly(MoneyKey.OVER_LIMIT, MoneyKey.MEET).inOrder()
        assertThat(agreed.phase).isEqualTo(1)

        vm.onEvent(ChatEvent.Console(ConsoleEvent.ConfirmMeeting))
        assertThat((vm.state.value.console as ConsoleState.AtMeeting).checked).isEqualTo(0)
        assertThat(vm.state.value.moneyNotes).containsExactly(MoneyKey.AFTER_PAY)
        vm.onEvent(ChatEvent.Console(ConsoleEvent.Check("k0", true)))
        assertThat((vm.state.value.console as ConsoleState.AtMeeting).checked).isEqualTo(1)

        vm.onEvent(ChatEvent.StartScan)
        assertThat(vm.state.value.scanning).isTrue()
        advanceTimeBy(1_700); runCurrent()
        assertThat(vm.state.value.console).isEqualTo(ConsoleState.Received)
        vm.onEvent(ChatEvent.Console(ConsoleEvent.Rate(5)))
        assertThat(vm.state.value.console).isEqualTo(ConsoleState.Done(5))
        assertThat(vm.state.value.phase).isEqualTo(4)
        assertThat(deal().thread.filterIsInstance<ThreadItem.Milestone>().map { it.kind })
            .containsExactly(MilestoneKind.AGREED, MilestoneKind.HANDED_OVER, MilestoneKind.RATED).inOrder()
    }

    @Test
    fun doubleTapSendsOnce() = runTest {
        failures.latencyMillis = 300
        val vm = viewModel()
        advanceTimeBy(400); runCurrent()
        vm.onEvent(ChatEvent.Console(ConsoleEvent.Accept))
        vm.onEvent(ChatEvent.Console(ConsoleEvent.Accept))
        assertThat(vm.state.value.pending).isTrue()
        advanceUntilIdle()
        assertThat(deals.sent.count { it == DealCommand.AcceptCounter }).isEqualTo(1)
        assertThat(vm.state.value.pending).isFalse()
    }

    @Test
    fun draftSurvivesRecreation() = runTest {
        val vm = viewModel()
        runCurrent()
        vm.onEvent(ChatEvent.Console(ConsoleEvent.StartOffer))
        vm.onEvent(ChatEvent.Console(ConsoleEvent.StepOffer(up = false)))
        vm.onEvent(ChatEvent.Compose("Ốp màu gì"))
        val again = viewModel(handle = saved)
        runCurrent()
        val offering = again.state.value.console as ConsoleState.Offering
        assertThat(offering.draft).isEqualTo(Vnd(10_400_000))
        assertThat(again.state.value.composer).isEqualTo("Ốp màu gì")
    }

    @Test
    fun failedHandoverIsNotShownAsDone() = runTest {
        at(DealStage.HANDOVER, tonight)
        val vm = viewModel()
        runCurrent()
        failures.rate = 1.0
        vm.messages.test {
            vm.onEvent(ChatEvent.StartScan)
            advanceTimeBy(1_700); runCurrent()
            assertThat(awaitItem().text).isEqualTo(DesignR.string.send_failed)
        }
        assertThat(vm.state.value.console).isInstanceOf(ConsoleState.AtMeeting::class.java)
        assertThat(deal().thread.none { it is ThreadItem.Milestone && it.kind == MilestoneKind.HANDED_OVER }).isTrue()
        assertThat(vm.state.value.scanning).isFalse()
    }

    @Test
    fun aFailedOfferRestoresTheEditorAndDropsThePill() = runTest {
        failures.latencyMillis = 300
        val vm = viewModel()
        advanceTimeBy(400); runCurrent()
        vm.onEvent(ChatEvent.Console(ConsoleEvent.StartOffer))
        failures.rate = 1.0
        vm.onEvent(ChatEvent.Console(ConsoleEvent.SendOffer))
        assertThat(vm.state.value.optimisticOffer).isEqualTo(Vnd(10_500_000))
        assertThat(vm.state.value.console).isEqualTo(ConsoleState.Waiting(Vnd(10_500_000)))
        advanceTimeBy(400); runCurrent()
        assertThat(vm.state.value.optimisticOffer).isNull()
        assertThat((vm.state.value.console as ConsoleState.Offering).draft).isEqualTo(Vnd(10_500_000))
        assertThat(deal().openOffer).isNull()
    }

    @Test
    fun theRecordIsRefundedAndConfirmed() = runTest {
        at(DealStage.DONE, tonight)
        val vm = viewModel()
        runCurrent()
        vm.onEvent(ChatEvent.OpenRecord)
        assertThat(vm.state.value.record!!.canSend).isFalse()
        vm.onEvent(ChatEvent.RecordPhoto("content://media/picker/1"))
        vm.onEvent(ChatEvent.RecordText("Mặt lưng có vết nứt nhỏ"))
        assertThat(vm.state.value.record!!.canSend).isTrue()
        vm.onEvent(ChatEvent.SendRecord)
        assertThat(vm.state.value.record).isNull()
        assertThat(deal().records.single().status).isEqualTo(RecordStatus.OPEN)
        advanceTimeBy(2_300); runCurrent()
        assertThat(deal().records.single().refund).isEqualTo(Vnd(300_000))
        vm.onEvent(ChatEvent.ConfirmRefund(RecordId("r1")))
        assertThat(deal().records.single().refundConfirmed).isTrue()
    }

    @Test
    fun theComposerSendsAndClears() = runTest {
        val vm = viewModel()
        runCurrent()
        vm.onEvent(ChatEvent.SendMessage)
        assertThat(deals.sent).isEmpty()
        vm.onEvent(ChatEvent.Compose("Ốp màu gì vậy bạn?"))
        vm.onEvent(ChatEvent.SendMessage)
        assertThat(vm.state.value.composer).isEmpty()
        assertThat((deal().thread.last() as ThreadItem.Text).text).isEqualTo("Ốp màu gì vậy bạn?")
    }
}
```

The three Review Focus cases are `doubleTapSendsOnce` (2), `draftSurvivesRecreation` (3) and `failedHandoverIsNotShownAsDone` (4).

Run: `./gradlew :feature:deal:testDebugUnitTest`
Expected: FAIL, `Unresolved reference 'ChatViewModel'`.

- [ ] **Step 3: Write the UI state and its builder**

`chat/ChatUiState.kt`:

```kotlin
package vn.shopnexus.feature.deal.chat

import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import vn.shopnexus.core.domain.ConsoleDraft
import vn.shopnexus.core.domain.ConsoleState
import vn.shopnexus.core.domain.DealConsole
import vn.shopnexus.core.domain.MoneyStep
import vn.shopnexus.core.domain.OfferCheck
import vn.shopnexus.core.domain.OfferRange
import vn.shopnexus.core.domain.meetingLabel
import vn.shopnexus.core.domain.moneyNotes
import vn.shopnexus.core.domain.offerRange
import vn.shopnexus.core.domain.todayAt
import vn.shopnexus.core.model.ChatView
import vn.shopnexus.core.model.Deal
import vn.shopnexus.core.model.MoneyKey
import vn.shopnexus.core.model.Party
import vn.shopnexus.core.model.Vnd

sealed interface ChatContent {
    data object Loading : ChatContent
    data object Failed : ChatContent
    data object Missing : ChatContent
    data class Ready(val view: ChatView) : ChatContent
}

/** A suggested amount; [middle] marks the one halfway between the buyer's last offer and the counter. */
data class OfferChip(val amount: Vnd, val middle: Boolean)

data class TimeOption(val at: Instant, val label: String)

data class RecordDraft(val photo: String?, val text: String) {
    val canSend: Boolean get() = photo != null && text.isNotBlank()
}

data class ChatUiState(
    val content: ChatContent = ChatContent.Loading,
    val console: ConsoleState? = null,
    /** 0 to 3 is the phase in progress; 4 means all four are done. */
    val phase: Int = 0,
    val offerChips: List<OfferChip> = emptyList(),
    val meetingText: String? = null,
    val counterHoursLeft: Long? = null,
    val pending: Boolean = false,
    val optimisticOffer: Vnd? = null,
    val typing: Boolean = false,
    val composer: String = "",
    val scanning: Boolean = false,
    val record: RecordDraft? = null,
    val timeOptions: List<TimeOption> = emptyList(),
    val moneyNotes: List<MoneyKey> = emptyList(),
)

/** What only this screen knows: a command in flight, checks not yet confirmed, the composer and the record draft. */
data class ChatLocal(
    val pending: Boolean = false,
    val optimisticOffer: Vnd? = null,
    val scanning: Boolean = false,
    val composer: String = "",
    val record: RecordDraft? = null,
    val checkOverrides: Map<String, Boolean> = emptyMap(),
)

/** Pure, so screenshot tests build every console state from the fixtures without a ViewModel. */
internal fun chatUiState(content: ChatContent, draft: ConsoleDraft, local: ChatLocal, typing: Boolean, now: Instant, zone: ZoneId): ChatUiState {
    val view = (content as? ChatContent.Ready)?.view
        ?: return ChatUiState(content = content, composer = local.composer, record = local.record)
    val deal = view.deal.let { d ->
        if (local.checkOverrides.isEmpty()) d
        else d.copy(checklist = d.checklist.map { c -> local.checkOverrides[c.id]?.let { c.copy(checked = it) } ?: c })
    }
    var console = DealConsole.state(deal, draft)
    // While an offer is on its way, the console waits on it; a failure puts the editor back.
    if (local.optimisticOffer != null && console is ConsoleState.Countered) console = ConsoleState.Waiting(local.optimisticOffer)
    val notes = when (console) {
        is ConsoleState.Agreed -> moneyNotes(MoneyStep.DEAL_AGREED, console.price)
        is ConsoleState.AtMeeting -> moneyNotes(MoneyStep.DEAL_MEETING, deal.agreedPrice ?: deal.listedPrice)
        else -> emptyList()
    }
    return ChatUiState(
        content = ChatContent.Ready(view.copy(deal = deal)),
        console = console,
        phase = deal.stage.ordinal,
        offerChips = offerChips(deal, offerRange(deal.listedPrice, deal.openCounter?.amount)),
        meetingText = deal.meeting?.let { "${meetingLabel(it.at, now, zone)} · ${it.place.name}" },
        counterHoursLeft = deal.counterExpiresAt?.let { Duration.between(now, it).toHours().coerceAtLeast(0) },
        pending = local.pending,
        optimisticOffer = local.optimisticOffer,
        typing = typing,
        composer = local.composer,
        scanning = local.scanning,
        record = local.record,
        timeOptions = timeOptions(now, zone),
        moneyNotes = notes,
    )
}

/** Up to three amounts below the counter: halfway first when there is a last offer, then the top steps. */
internal fun offerChips(deal: Deal, range: OfferRange): List<OfferChip> {
    val counter = deal.openCounter?.amount
    val lastMine = deal.offers.lastOrNull { it.by == Party.BUYER }?.amount
    val step = range.step.amount
    val middle = if (counter != null && lastMine != null) Vnd((lastMine.amount + counter.amount) / 2 / step * step) else null
    val top = (0 until 3).map { Vnd(range.highest.amount - it * step) }
    return (listOfNotNull(middle) + top).distinct()
        .filter { range.check(it) is OfferCheck.Ok }
        .take(3)
        .map { OfferChip(it, middle = it == middle) }
}

/** The meeting times "Hẹn gặp" offers: three this evening and one tomorrow, the past ones left out. */
internal fun timeOptions(now: Instant, zone: ZoneId): List<TimeOption> {
    val tonight = listOf(18 to 30, 19 to 0, 20 to 0).map { (h, m) -> todayAt(h, m, now, zone) }
    val tomorrow = todayAt(19, 0, now, zone).plus(Duration.ofDays(1))
    return (tonight + tomorrow).filter { it.isAfter(now) }.map { TimeOption(it, meetingLabel(it, now, zone)) }
}
```

- [ ] **Step 4: Write the ViewModel**

`chat/ChatViewModel.kt`:

```kotlin
package vn.shopnexus.feature.deal.chat

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.assisted.Assisted
import dagger.assisted.AssistedFactory
import dagger.assisted.AssistedInject
import dagger.hilt.android.lifecycle.HiltViewModel
import java.time.Clock
import java.time.ZoneId
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import vn.shopnexus.core.data.DealRepository
import vn.shopnexus.core.data.QrScanner
import vn.shopnexus.core.designsystem.component.UiMessage
import vn.shopnexus.core.domain.ConsoleDraft
import vn.shopnexus.core.domain.ConsoleEvent
import vn.shopnexus.core.domain.DealConsole
import vn.shopnexus.core.model.ChatView
import vn.shopnexus.core.model.DealCommand
import vn.shopnexus.core.model.DealId
import vn.shopnexus.core.model.RecordId
import vn.shopnexus.core.model.Vnd
import vn.shopnexus.core.navigation.ChatRoute
import vn.shopnexus.feature.deal.R
import vn.shopnexus.core.designsystem.R as DesignR

sealed interface ChatEvent {
    data object Retry : ChatEvent
    data class Console(val event: ConsoleEvent) : ChatEvent
    data class Compose(val text: String) : ChatEvent
    data object SendMessage : ChatEvent
    data class Reply(val text: String) : ChatEvent
    data object StartScan : ChatEvent
    data object CancelScan : ChatEvent
    data object OpenRecord : ChatEvent
    data object CloseRecord : ChatEvent
    data class RecordPhoto(val uri: String) : ChatEvent
    data class RecordText(val text: String) : ChatEvent
    data object SendRecord : ChatEvent
    data class ConfirmRefund(val id: RecordId) : ChatEvent
}

private const val EDITING = "console.editing"
private const val AMOUNT = "console.amount"
private const val COMPOSER = "composer"
private const val RECORD_OPEN = "record.open"
private const val RECORD_PHOTO = "record.photo"
private const val RECORD_TEXT = "record.text"
private const val NONE = -1L

@OptIn(ExperimentalCoroutinesApi::class)
@HiltViewModel(assistedFactory = ChatViewModel.Factory::class)
class ChatViewModel @AssistedInject constructor(
    @Assisted route: ChatRoute,
    private val deals: DealRepository,
    private val scanner: QrScanner,
    private val clock: Clock,
    private val zone: ZoneId,
    private val saved: SavedStateHandle,
) : ViewModel() {
    @AssistedFactory
    interface Factory {
        fun create(route: ChatRoute): ChatViewModel
    }

    private val id = DealId(route.dealId)
    private val attempt = MutableStateFlow(0)
    private val draft = MutableStateFlow(
        ConsoleDraft(saved[EDITING] ?: false, saved.get<Long>(AMOUNT)?.takeIf { it != NONE }?.let(::Vnd)),
    )
    private val local = MutableStateFlow(
        ChatLocal(
            composer = saved[COMPOSER] ?: "",
            record = if (saved[RECORD_OPEN] == true) RecordDraft(saved[RECORD_PHOTO], saved[RECORD_TEXT] ?: "") else null,
        ),
    )
    private val outbox = Channel<UiMessage>(Channel.BUFFERED)
    val messages: Flow<UiMessage> = outbox.receiveAsFlow()
    private var scanJob: Job? = null

    private val content: StateFlow<ChatContent> = attempt.flatMapLatest {
        deals.chat(id)
            .map<ChatView?, ChatContent> { it?.let(ChatContent::Ready) ?: ChatContent.Missing }
            .onStart { emit(ChatContent.Loading) }
            .catch { emit(ChatContent.Failed) }
    }.stateIn(viewModelScope, SharingStarted.Eagerly, ChatContent.Loading)

    private val typing: Flow<Boolean> = deals.counterpartTyping(id).catch { emit(false) }

    val state: StateFlow<ChatUiState> = combine(content, draft, local, typing) { c, d, l, t ->
        chatUiState(c, d, l, t, clock.instant(), zone)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), ChatUiState())

    fun onEvent(event: ChatEvent) {
        when (event) {
            ChatEvent.Retry -> attempt.update { it + 1 }
            is ChatEvent.Console -> console(event.event)
            is ChatEvent.Compose -> setComposer(event.text.take(1_000))
            ChatEvent.SendMessage -> sendText(local.value.composer, fromComposer = true)
            is ChatEvent.Reply -> sendText(event.text, fromComposer = false)
            ChatEvent.StartScan -> scan()
            ChatEvent.CancelScan -> {
                scanJob?.cancel()
                local.update { it.copy(scanning = false) }
            }
            ChatEvent.OpenRecord -> setRecord(RecordDraft(null, ""))
            ChatEvent.CloseRecord -> setRecord(null)
            is ChatEvent.RecordPhoto -> local.value.record?.let { setRecord(it.copy(photo = event.uri)) }
            is ChatEvent.RecordText -> local.value.record?.let { setRecord(it.copy(text = event.text.take(1_000))) }
            ChatEvent.SendRecord -> local.value.record?.takeIf { it.canSend }?.let { r ->
                dispatch(DealCommand.OpenRecord(r.photo!!, r.text.trim()), onSuccess = { setRecord(null) })
            }
            is ChatEvent.ConfirmRefund -> dispatch(DealCommand.ConfirmRefund(event.id))
        }
    }

    private fun console(event: ConsoleEvent) {
        val deal = (content.value as? ChatContent.Ready)?.view?.deal ?: return
        if (event is ConsoleEvent.Check) return setCheck(event)
        val step = DealConsole.reduce(deal, draft.value, event)
        val command = step.command ?: return setDraft(step.draft)
        if (local.value.pending) return
        val before = draft.value
        setDraft(step.draft)
        dispatch(command, onFailure = { setDraft(before) })
    }

    /** One command at a time; the console's buttons stay disabled while [ChatLocal.pending] is set. */
    private fun dispatch(command: DealCommand, onSuccess: () -> Unit = {}, onFailure: () -> Unit = {}) {
        if (local.value.pending) return
        local.update { it.copy(pending = true, optimisticOffer = (command as? DealCommand.SendOffer)?.amount) }
        viewModelScope.launch {
            deals.send(id, command)
                .onSuccess { onSuccess() }
                .onFailure {
                    onFailure()
                    outbox.send(UiMessage(DesignR.string.send_failed))
                }
            local.update { it.copy(pending = false, optimisticOffer = null) }
        }
    }

    /** Checks show at once and do not wait for other commands; a failed one falls back to what the deal says. */
    private fun setCheck(event: ConsoleEvent.Check) {
        local.update { it.copy(checkOverrides = it.checkOverrides + (event.itemId to event.checked)) }
        viewModelScope.launch {
            deals.send(id, DealCommand.SetCheck(event.itemId, event.checked))
                .onFailure { outbox.send(UiMessage(DesignR.string.send_failed)) }
            local.update { it.copy(checkOverrides = it.checkOverrides - event.itemId) }
        }
    }

    private fun scan() {
        if (local.value.pending || local.value.scanning) return
        local.update { it.copy(scanning = true) }
        scanJob = viewModelScope.launch {
            val code = scanner.scan()
            local.update { it.copy(scanning = false) }
            code.onSuccess { console(ConsoleEvent.Scan(it)) }
                .onFailure { outbox.send(UiMessage(R.string.scan_failed)) }
        }
    }

    private fun sendText(text: String, fromComposer: Boolean) {
        val message = text.trim()
        if (message.isEmpty()) return
        if (fromComposer) setComposer("")
        viewModelScope.launch {
            deals.send(id, DealCommand.SendText(message)).onFailure {
                if (fromComposer && local.value.composer.isEmpty()) setComposer(message)
                outbox.send(UiMessage(DesignR.string.send_failed))
            }
        }
    }

    private fun setDraft(value: ConsoleDraft) {
        draft.value = value
        saved[EDITING] = value.editing
        saved[AMOUNT] = value.amount?.amount ?: NONE
    }

    private fun setComposer(text: String) {
        local.update { it.copy(composer = text) }
        saved[COMPOSER] = text
    }

    private fun setRecord(record: RecordDraft?) {
        local.update { it.copy(record = record) }
        saved[RECORD_OPEN] = record != null
        saved[RECORD_PHOTO] = record?.photo
        saved[RECORD_TEXT] = record?.text.orEmpty()
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./gradlew :feature:deal:testDebugUnitTest`
Expected: PASS, 8 tests.

- [ ] **Step 6: Commit**

```bash
git add settings.gradle.kts app feature/deal
git commit -m "feat(deal): add the Chat ViewModel over the deal console

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 22: The Chat screen

The thread, the deal console in its eight states, the composer with quick replies, the "Hẹn gặp" and "Danh sách kiểm" sheets, the "Chưa kiểm xong" dialog, the scanner, and the incident record with the Android Photo Picker.

**Files:**
- Create in `app2/feature/deal/src/main/kotlin/vn/shopnexus/feature/deal/chat/`: `ChatScreen.kt`, `Thread.kt`, `Console.kt`, `Composer.kt`, `Sheets.kt`, `Scanner.kt`
- Create: `app2/feature/deal/src/main/kotlin/vn/shopnexus/feature/deal/DealInstaller.kt`
- Test: `app2/feature/deal/src/test/kotlin/vn/shopnexus/feature/deal/chat/ChatScreenTest.kt`

**Interfaces:**
- Consumes: Task 21; components (Tasks 13–16, 19).
- Produces:
  ```kotlin
  @Composable fun ChatScreen(state: ChatUiState, onEvent: (ChatEvent) -> Unit, onNavigate: (NavKey) -> Unit, onBack: () -> Unit,
                             snackbar: SnackbarHostState, modifier: Modifier = Modifier, animate: Boolean = true)
  class DealInstaller : EntryInstaller   // ChatRoute
  ```

- [ ] **Step 1: Write the failing screen test**

`ChatScreenTest.kt`:

```kotlin
package vn.shopnexus.feature.deal.chat

import androidx.compose.material3.SnackbarHostState
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.navigation3.runtime.NavKey
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.common.truth.Truth.assertThat
import java.time.Instant
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import vn.shopnexus.core.data.fake.Fixtures
import vn.shopnexus.core.domain.ConsoleDraft
import vn.shopnexus.core.domain.ConsoleEvent
import vn.shopnexus.core.domain.VN_ZONE
import vn.shopnexus.core.model.DealStage
import vn.shopnexus.core.model.IncidentRecord
import vn.shopnexus.core.model.MeetPoint
import vn.shopnexus.core.model.Meeting
import vn.shopnexus.core.model.MilestoneKind
import vn.shopnexus.core.model.Offer
import vn.shopnexus.core.model.OfferStatus
import vn.shopnexus.core.model.Party
import vn.shopnexus.core.model.RecordId
import vn.shopnexus.core.model.RecordStatus
import vn.shopnexus.core.model.ThreadItem
import vn.shopnexus.core.model.Vnd
import vn.shopnexus.core.navigation.ListingRoute
import vn.shopnexus.core.testing.Variant
import vn.shopnexus.core.testing.VariantFrame
import vn.shopnexus.core.testing.assertNoClippedText
import vn.shopnexus.core.testing.captureAllWindows
import vn.shopnexus.core.testing.captureScreen
import vn.shopnexus.core.testing.captureVariants
import vn.shopnexus.core.testing.fakeImages

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w412dp-h915dp-xhdpi")
class ChatScreenTest {
    @get:Rule val compose = createComposeRule()
    private val now = Fixtures.NOW
    private val view = Fixtures.chat("d-kiet")
    private val idle = ConsoleDraft(editing = false, amount = null)
    private val landmark = MeetPoint("Sảnh Landmark 81", "Có bảo vệ, đông người")
    private val tonight = Meeting(Instant.parse("2026-10-15T12:00:00Z"), landmark, Party.SELLER, confirmed = false)
    private val events = mutableListOf<ChatEvent>()
    private val pushed = mutableListOf<NavKey>()

    private fun state(
        stage: DealStage = DealStage.NEGOTIATE,
        draft: ConsoleDraft = idle,
        local: ChatLocal = ChatLocal(),
        edit: (vn.shopnexus.core.model.Deal) -> vn.shopnexus.core.model.Deal = { it },
    ): ChatUiState {
        val deal = edit(view.deal.copy(stage = stage))
        return chatUiState(ChatContent.Ready(view.copy(deal = deal)), draft, local, typing = false, now, VN_ZONE)
    }

    private val agreed = { d: vn.shopnexus.core.model.Deal ->
        d.copy(agreedPrice = Vnd(10_600_000), meeting = tonight, thread = d.thread + ThreadItem.Milestone(MilestoneKind.AGREED, now))
    }
    private val atMeeting = { d: vn.shopnexus.core.model.Deal -> agreed(d).copy(meeting = tonight.copy(confirmed = true)) }

    private fun show(s: ChatUiState, variant: Variant = Variant.LIGHT) {
        fakeImages()
        compose.setContent { VariantFrame(variant) { ChatScreen(s, { events += it }, { pushed += it }, {}, SnackbarHostState(), animate = false) } }
    }

    @Test
    fun theCounterOffersTwoActionsAndTheTitleOpensTheListing() {
        show(state())
        compose.onNodeWithText("Đồng ý").performClick()
        compose.onNodeWithText("Trả giá").performClick()
        compose.onNodeWithContentDescription("Xem tin iPhone 13 Pro 128GB, Xanh Sierra, pin 88%").performClick()
        assertThat(events).containsExactly(ChatEvent.Console(ConsoleEvent.Accept), ChatEvent.Console(ConsoleEvent.StartOffer)).inOrder()
        assertThat(pushed).containsExactly(ListingRoute("p-iphone13"))
    }

    @Test
    fun aPendingCommandDisablesTheConsole() {
        show(state(local = ChatLocal(pending = true)))
        compose.onNodeWithText("Đồng ý").assertIsNotEnabled()
        compose.onNodeWithText("Trả giá").assertIsNotEnabled()
    }

    @Test
    fun typingFoldsTheConsoleAndShowsQuickReplies() {
        show(state())
        compose.onNodeWithContentDescription("Nhắn tin cho Tuấn Kiệt").performTextInput("Ố")
        compose.onNodeWithText("Đồng ý").assertDoesNotExist()
        compose.onNodeWithText("Xem máy trước được không?").assertExists()
    }

    @Test
    fun scanningWithUncheckedItemsAsksFirst() {
        show(state(DealStage.HANDOVER, edit = atMeeting))
        compose.onNodeWithText("Quét mã").performClick()
        compose.onNodeWithText("Còn 6 mục chưa kiểm. Đã trả tiền thì ShopNexus không đòi lại được.").assertExists()
        compose.onNodeWithText("Vẫn quét").performClick()
        assertThat(events).containsExactly(ChatEvent.StartScan)
    }

    @Test
    fun theRecordCannotBeSentWithoutAPhoto() {
        show(state(DealStage.DONE, local = ChatLocal(record = RecordDraft(null, "Mặt lưng có vết nứt nhỏ")), edit = { atMeeting(it).copy(rating = 5) }))
        compose.onNodeWithText("Gửi ghi nhận").assertIsNotEnabled()
    }

    @Test
    fun textFitsAtFontScale130() {
        show(state(DealStage.HANDOVER, edit = atMeeting), Variant.FONT_130)
        compose.assertNoClippedText()
    }

    @Test
    fun countered() = compose.captureVariants("chat-countered") { ChatScreen(state(), {}, {}, {}, SnackbarHostState(), animate = false) }

    @Test
    fun offering() = compose.captureScreen("chat-offering") {
        ChatScreen(state(draft = ConsoleDraft(true, Vnd(10_500_000))), {}, {}, {}, SnackbarHostState(), animate = false)
    }

    @Test
    fun waiting() = compose.captureScreen("chat-waiting") {
        ChatScreen(state(edit = { it.copy(offers = it.offers + Offer(Party.BUYER, Vnd(10_500_000), now, OfferStatus.OPEN)) }), {}, {}, {}, SnackbarHostState(), animate = false)
    }

    @Test
    fun agreedState() = compose.captureScreen("chat-agreed") { ChatScreen(state(DealStage.ARRANGE, edit = agreed), {}, {}, {}, SnackbarHostState(), animate = false) }

    @Test
    fun proposing() = compose.captureScreen("chat-proposing") {
        ChatScreen(state(DealStage.ARRANGE, edit = { agreed(it).copy(meeting = tonight.copy(proposedBy = Party.BUYER)) }), {}, {}, {}, SnackbarHostState(), animate = false)
    }

    @Test
    fun meeting() = compose.captureVariants("chat-meeting") { ChatScreen(state(DealStage.HANDOVER, edit = atMeeting), {}, {}, {}, SnackbarHostState(), animate = false) }

    @Test
    fun received() = compose.captureScreen("chat-received") {
        ChatScreen(state(DealStage.RATE, edit = { atMeeting(it).copy(thread = it.thread + ThreadItem.Milestone(MilestoneKind.HANDED_OVER, now)) }), {}, {}, {}, SnackbarHostState(), animate = false)
    }

    @Test
    fun doneWithARefund() = compose.captureScreen("chat-done") {
        val record = IncidentRecord(RecordId("r1"), Party.BUYER, "", "Mặt lưng có vết nứt nhỏ", "Tin đã khai 2 vết xước nhỏ ở viền. Vết khác chưa có trong ảnh và mô tả của tin.", RecordStatus.REFUNDED, Vnd(300_000))
        ChatScreen(
            state(DealStage.DONE, edit = { atMeeting(it).copy(rating = 5, records = listOf(record), thread = it.thread + ThreadItem.Record(record.id, now)) }),
            {}, {}, {}, SnackbarHostState(), animate = false,
        )
    }

    @Test
    fun checklistSheet() {
        show(state(DealStage.HANDOVER, edit = atMeeting))
        compose.onNodeWithText("Kiểm máy 0/6").performClick()
        compose.waitForIdle()
        captureAllWindows("chat-checklist")
    }

    @Test
    fun scheduleSheet() {
        show(state(DealStage.ARRANGE, edit = agreed))
        compose.onNodeWithContentDescription("Đổi giờ hẹn").performClick()
        compose.waitForIdle()
        captureAllWindows("chat-schedule")
    }
}
```

Run: `./gradlew :feature:deal:testDebugUnitTest --tests "*ChatScreenTest*"`
Expected: FAIL, `Unresolved reference 'ChatScreen'`.

- [ ] **Step 2: Write the thread**

`chat/Thread.kt`:

```kotlin
package vn.shopnexus.feature.deal.chat

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import java.time.format.DateTimeFormatter
import vn.shopnexus.core.designsystem.component.Milestone
import vn.shopnexus.core.designsystem.component.MilestoneTone
import vn.shopnexus.core.designsystem.component.SparkleLabel
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.core.designsystem.theme.Corners
import vn.shopnexus.core.designsystem.theme.ShopNexusTheme
import vn.shopnexus.core.domain.VN_ZONE
import vn.shopnexus.core.model.ChatView
import vn.shopnexus.core.model.IncidentRecord
import vn.shopnexus.core.model.MilestoneKind
import vn.shopnexus.core.model.Party
import vn.shopnexus.core.model.RecordId
import vn.shopnexus.core.model.RecordStatus
import vn.shopnexus.core.model.ThreadItem
import vn.shopnexus.core.model.Vnd
import vn.shopnexus.core.model.full
import vn.shopnexus.core.model.short
import vn.shopnexus.feature.deal.R

private val TIME = DateTimeFormatter.ofPattern("HH:mm").withZone(VN_ZONE)

/** One line of the thread as drawn: an item, a pending offer, or the typing dots. */
private sealed interface Line {
    data class Item(val item: ThreadItem, val lastOfGroup: Boolean, val firstOfGroup: Boolean) : Line
    data class Pending(val amount: Vnd) : Line
    data object Typing : Line
}

private fun ThreadItem.sender(): Party? = when (this) {
    is ThreadItem.Text -> by
    is ThreadItem.Photos -> by
    is ThreadItem.PriceMove -> by
    else -> null
}

private fun lines(view: ChatView, pending: Vnd?, typing: Boolean): List<Line> {
    val items = view.deal.thread
    val out = items.mapIndexed { i, item ->
        val who = item.sender()
        val prev = items.getOrNull(i - 1)?.sender()
        val next = items.getOrNull(i + 1)?.sender()
        Line.Item(item, lastOfGroup = who == null || next != who, firstOfGroup = who == null || prev != who)
    }
    return out + listOfNotNull(pending?.let(Line::Pending), if (typing) Line.Typing else null)
}

/** The thread, newest at the bottom; reversed, so it stays pinned to the newest message while the console changes height. */
@Composable
internal fun ChatThread(
    view: ChatView,
    pendingOffer: Vnd?,
    typing: Boolean,
    animate: Boolean,
    onConfirmRefund: (RecordId) -> Unit,
    state: LazyListState,
    modifier: Modifier = Modifier,
) {
    val lines = lines(view, pendingOffer, typing).asReversed()
    LazyColumn(modifier, state = state, reverseLayout = true, contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp)) {
        items(lines.size) { i ->
            when (val line = lines[i]) {
                is Line.Item -> ThreadRow(view, line, animate, onConfirmRefund)
                is Line.Pending -> PriceMovePill(Party.BUYER, line.amount, accepted = false, time = stringResource(R.string.sending), name = stringResource(R.string.you), pending = true)
                Line.Typing -> TypingDots(view.counterpart.name)
            }
        }
        item {
            Row(Modifier.fillMaxWidth().padding(bottom = 16.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                SymbolIcon(Symbol.Shield, contentDescription = null, size = 16.dp, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(stringResource(R.string.thread_opener), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 6.dp))
            }
        }
    }
}

@Composable
private fun ThreadRow(view: ChatView, row: Line.Item, animate: Boolean, onConfirmRefund: (RecordId) -> Unit) {
    val time = TIME.format(row.item.at)
    val them = view.counterpart.name
    Box(Modifier.padding(top = if (row.firstOfGroup) 12.dp else 2.dp)) {
        when (val item = row.item) {
            is ThreadItem.Text -> Bubble(item.by, item.text, if (row.lastOfGroup) time else null, row.firstOfGroup, row.lastOfGroup)
            is ThreadItem.Photos -> PhotoRow(item.by, item.urls)
            is ThreadItem.PriceMove -> PriceMovePill(item.by, item.amount, item.accepted, time, if (item.by == Party.BUYER) stringResource(R.string.you) else them)
            is ThreadItem.Event -> EventLine(item.icon, item.text)
            is ThreadItem.Milestone -> MilestoneItem(item.kind, view, animate)
            is ThreadItem.Record -> view.deal.records.find { it.id == item.recordId }?.let { RecordCard(it, them, onConfirmRefund) }
        }
    }
}

@Composable
private fun Bubble(by: Party, text: String, time: String?, first: Boolean, last: Boolean) {
    val mine = by == Party.BUYER
    val c = MaterialTheme.colorScheme
    val maxWidth = (LocalConfiguration.current.screenWidthDp * 0.8f).dp
    val tuck = 4.dp
    val shape = if (mine) RoundedCornerShape(20.dp, if (first) 20.dp else tuck, if (last) 20.dp else tuck, 20.dp)
    else RoundedCornerShape(if (first) 20.dp else tuck, 20.dp, 20.dp, if (last) 20.dp else tuck)
    Column(Modifier.fillMaxWidth(), horizontalAlignment = if (mine) Alignment.End else Alignment.Start) {
        Text(
            text,
            style = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.widthIn(max = maxWidth).background(if (mine) c.secondaryContainer else c.surfaceContainerHigh, shape).padding(horizontal = 16.dp, vertical = 10.dp),
        )
        if (time != null) Text(time, style = MaterialTheme.typography.bodySmall, color = c.onSurfaceVariant, modifier = Modifier.padding(top = 4.dp, start = 4.dp, end = 4.dp))
    }
}

@Composable
private fun PhotoRow(by: Party, urls: List<String>) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, if (by == Party.BUYER) Alignment.End else Alignment.Start)) {
        urls.forEach { url ->
            AsyncImage(url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.size(132.dp).clip(Corners.Medium).background(MaterialTheme.colorScheme.surfaceContainerHigh))
        }
    }
}

/** An offer is tonal terracotta with a tag; an acceptance is secondaryContainer with a check. */
@Composable
private fun PriceMovePill(by: Party, amount: Vnd, accepted: Boolean, time: String, name: String, pending: Boolean = false) {
    val c = MaterialTheme.colorScheme
    val (fill, ink) = if (accepted) c.secondaryContainer to c.onSecondaryContainer
    else ShopNexusTheme.extended.tertiaryFixed to ShopNexusTheme.extended.onTertiaryFixedVariant
    val label = stringResource(if (accepted) R.string.move_accept else R.string.move_offer, name, amount.full())
    Column(Modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = label }, horizontalAlignment = if (by == Party.BUYER) Alignment.End else Alignment.Start) {
        Row(
            Modifier.height(40.dp).alpha(if (pending) 0.6f else 1f).background(fill, CircleShape).padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            SymbolIcon(if (accepted) Symbol.Check else Symbol.Sell, contentDescription = null, size = 18.dp, tint = ink)
            Text(amount.short(), style = MaterialTheme.typography.titleSmall, color = ink)
        }
        Text(time, style = MaterialTheme.typography.bodySmall, color = c.onSurfaceVariant, modifier = Modifier.padding(top = 4.dp))
    }
}

@Composable
private fun EventLine(icon: String, text: String) {
    val c = MaterialTheme.colorScheme
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        SymbolIcon(Symbol.of(icon) ?: Symbol.Info, contentDescription = null, size = 16.dp, tint = c.onSurfaceVariant)
        Text(text, style = MaterialTheme.typography.labelMedium, color = c.onSurfaceVariant, modifier = Modifier.padding(start = 6.dp))
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun MilestoneItem(kind: MilestoneKind, view: ChatView, animate: Boolean) {
    when (kind) {
        MilestoneKind.AGREED -> Milestone(
            MaterialShapes.Cookie9Sided, MilestoneTone.DEAL, Symbol.Handshake,
            stringResource(R.string.milestone_agreed, (view.deal.agreedPrice ?: view.deal.listedPrice).short()),
            stringResource(R.string.milestone_agreed_line), animate = animate,
        )
        MilestoneKind.HANDED_OVER -> Milestone(
            MaterialShapes.SoftBurst, MilestoneTone.TRUST, Symbol.QrCodeTwo,
            stringResource(R.string.milestone_handed), stringResource(R.string.milestone_handed_line), animate = animate,
        )
        MilestoneKind.RATED -> Milestone(
            MaterialShapes.Flower, MilestoneTone.CALM, Symbol.Star,
            stringResource(R.string.milestone_rated), stringResource(R.string.milestone_rated_line), size = 72.dp, animate = animate,
        )
    }
}

/** A record: status chip, photo and text, the AI's neutral note, and who sees it. ShopNexus records and does not rule. */
@Composable
private fun RecordCard(record: IncidentRecord, seller: String, onConfirmRefund: (RecordId) -> Unit) {
    val c = MaterialTheme.colorScheme
    val status = when {
        record.refundConfirmed -> stringResource(R.string.record_done)
        record.status == RecordStatus.REFUNDED -> stringResource(R.string.record_refunded, seller, record.refund!!.full())
        record.status == RecordStatus.DECLINED -> stringResource(R.string.record_declined, seller)
        else -> stringResource(R.string.record_waiting, seller)
    }
    Column(Modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth().background(c.surfaceContainerHigh, Corners.ExtraLarge).padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                SymbolIcon(Symbol.Report, contentDescription = null, size = 20.dp, tint = c.onSurfaceVariant)
                Text(stringResource(R.string.record_title), style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                Text(status, style = MaterialTheme.typography.labelMedium, color = c.onSurfaceVariant, modifier = Modifier.background(c.surfaceContainerHighest, CircleShape).padding(horizontal = 10.dp, vertical = 2.dp))
            }
            Row(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                AsyncImage(record.photoUrl, contentDescription = stringResource(R.string.record_photo), contentScale = ContentScale.Crop, modifier = Modifier.size(64.dp).clip(Corners.Large).background(c.surfaceContainer))
                Text(record.text, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
            }
            SparkleLabel(record.aiNote, modifier = Modifier.padding(top = 12.dp), maxLines = 4)
            if (record.status == RecordStatus.REFUNDED && !record.refundConfirmed) {
                FilledTonalButton(onClick = { onConfirmRefund(record.id) }, modifier = Modifier.padding(top = 12.dp).fillMaxWidth().height(40.dp)) {
                    SymbolIcon(Symbol.Check, contentDescription = null, size = 18.dp)
                    Text(stringResource(R.string.record_received), modifier = Modifier.padding(start = 8.dp))
                }
            }
        }
        Text(stringResource(R.string.record_public), style = MaterialTheme.typography.bodySmall, color = c.onSurfaceVariant, modifier = Modifier.padding(top = 4.dp, start = 8.dp))
    }
}

/** Three pulsing dots while the other side types. */
@Composable
private fun TypingDots(name: String) {
    val pulse = rememberInfiniteTransition(label = "typing")
    val label = stringResource(R.string.typing, name)
    Row(
        Modifier.padding(top = 12.dp).background(MaterialTheme.colorScheme.surfaceContainerHigh, CircleShape).padding(horizontal = 16.dp, vertical = 12.dp)
            .clearAndSetSemantics { contentDescription = label },
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        repeat(3) { i ->
            val a = pulse.animateFloat(0.3f, 1f, infiniteRepeatable(tween(600, delayMillis = i * 150), RepeatMode.Reverse), label = "dot$i")
            Box(Modifier.size(8.dp).alpha(a.value).background(MaterialTheme.colorScheme.onSurfaceVariant, CircleShape))
        }
    }
}
```

- [ ] **Step 3: Write the console**

`chat/Console.kt`:

```kotlin
package vn.shopnexus.feature.deal.chat

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import vn.shopnexus.core.designsystem.component.AmountStepper
import vn.shopnexus.core.designsystem.component.Figure
import vn.shopnexus.core.designsystem.component.MoneyNote
import vn.shopnexus.core.designsystem.component.PhaseSet
import vn.shopnexus.core.designsystem.component.PhaseStepper
import vn.shopnexus.core.designsystem.component.SparkleLabel
import vn.shopnexus.core.designsystem.component.insightText
import vn.shopnexus.core.designsystem.component.offerCheckText
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.core.designsystem.theme.Corners
import vn.shopnexus.core.designsystem.theme.ShopNexusTheme
import vn.shopnexus.core.domain.ConsoleEvent
import vn.shopnexus.core.domain.ConsoleState
import vn.shopnexus.core.domain.OfferCheck
import vn.shopnexus.core.model.ChatView
import vn.shopnexus.core.model.Party
import vn.shopnexus.core.model.Vnd
import vn.shopnexus.core.model.full
import vn.shopnexus.core.model.short
import vn.shopnexus.feature.deal.R

/** What the console's buttons open; the screen holds the sheets and the dialog. */
internal class ConsoleActions(
    val onEvent: (ChatEvent) -> Unit,
    val onSchedule: () -> Unit,
    val onChecklist: () -> Unit,
    val onScan: () -> Unit,
    val onRecord: () -> Unit,
)

/**
 * The deal and its next action: the phase stepper and a fold button on top, then the body of the
 * current state. Folded (while typing) it keeps one row: the current phase, the figure, the chevron.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
internal fun DealConsoleCard(
    state: ChatUiState,
    view: ChatView,
    folded: Boolean,
    onFold: (Boolean) -> Unit,
    actions: ConsoleActions,
    modifier: Modifier = Modifier,
) {
    val console = state.console ?: return
    val c = MaterialTheme.colorScheme
    val enter = MaterialTheme.motionScheme.defaultEffectsSpec<Float>()
    val exit = MaterialTheme.motionScheme.fastEffectsSpec<Float>()
    Column(
        modifier.padding(horizontal = 12.dp).fillMaxWidth().clip(Corners.ExtraLarge).background(c.surfaceContainer).padding(16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            PhaseStepper(state.phase, PhaseSet.MEET, Modifier.weight(1f), small = folded)
            if (folded) figureOf(console, view)?.let { Text(it.short(), style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(horizontal = 12.dp)) }
            FilledTonalIconButton(
                onClick = { onFold(!folded) },
                colors = IconButtonDefaults.filledTonalIconButtonColors(containerColor = c.surfaceContainerHighest),
                modifier = Modifier.padding(start = 8.dp).size(32.dp),
            ) {
                SymbolIcon(Symbol.ExpandMore, stringResource(if (folded) R.string.unfold else R.string.fold), size = 20.dp,
                    modifier = if (folded) Modifier else Modifier.rotate(180f))
            }
        }
        if (!folded) {
            AnimatedContent(
                targetState = console,
                contentKey = { it::class },
                transitionSpec = { fadeIn(enter) togetherWith fadeOut(exit) using SizeTransform(clip = false) },
                label = "console",
            ) { s ->
                Column(Modifier.padding(top = 16.dp)) { ConsoleBody(s, state, view, actions) }
            }
        }
    }
}

/** The figure a state is about, for the folded row. */
private fun figureOf(s: ConsoleState, view: ChatView): Vnd? = when (s) {
    is ConsoleState.Countered -> s.counter
    is ConsoleState.Offering -> s.draft
    is ConsoleState.Waiting -> s.offer
    is ConsoleState.Agreed -> s.price
    else -> view.deal.agreedPrice
}

@Composable
private fun ColumnScope.ConsoleBody(s: ConsoleState, state: ChatUiState, view: ChatView, a: ConsoleActions) {
    val c = MaterialTheme.colorScheme
    val seller = view.counterpart.name
    val busy = state.pending
    val console = { e: ConsoleEvent -> a.onEvent(ChatEvent.Console(e)) }
    when (s) {
        is ConsoleState.Countered -> {
            FigureRow(view.counterpart.avatarUrl, s.counter)
            Row(Modifier.padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                s.insight?.let { SparkleLabel(insightText(it), priceTalk = true) }
                state.counterHoursLeft?.let { IconLine(Symbol.Timer, stringResource(R.string.counter_expires, it.toInt())) }
            }
            ActionRow {
                FilledTonalButton(
                    onClick = { console(ConsoleEvent.StartOffer) },
                    enabled = !busy,
                    colors = ButtonDefaults.filledTonalButtonColors(
                        containerColor = ShopNexusTheme.extended.tertiaryFixed,
                        contentColor = ShopNexusTheme.extended.onTertiaryFixedVariant,
                    ),
                    modifier = Modifier.weight(1f).height(56.dp),
                ) { Text(stringResource(R.string.make_offer)) }
                Button(onClick = { console(ConsoleEvent.Accept) }, enabled = !busy, modifier = Modifier.weight(1f).height(56.dp)) {
                    Text(stringResource(R.string.accept))
                }
            }
        }
        is ConsoleState.Offering -> {
            AmountStepper(s.draft, s.range, onStep = { console(ConsoleEvent.StepOffer(it)) }, onType = { console(ConsoleEvent.TypeOffer(it)) })
            Text(
                offerCheckText(s.check),
                style = MaterialTheme.typography.bodySmall,
                color = if (s.check is OfferCheck.Ok) c.onSurfaceVariant else c.error,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
            )
            LazyRow(Modifier.padding(top = 12.dp).align(Alignment.CenterHorizontally), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(state.offerChips) { chip ->
                    FilterChip(
                        selected = s.draft == chip.amount,
                        onClick = { console(ConsoleEvent.PickOffer(chip.amount)) },
                        label = { Text(chip.amount.short()) },
                        leadingIcon = if (chip.middle) { { SymbolIcon(Symbol.Balance, stringResource(R.string.meet_middle), size = 18.dp) } } else null,
                        shape = CircleShape,
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = ShopNexusTheme.extended.tertiaryFixed,
                            selectedLabelColor = ShopNexusTheme.extended.onTertiaryFixedVariant,
                            selectedLeadingIconColor = ShopNexusTheme.extended.onTertiaryFixedVariant,
                        ),
                    )
                }
            }
            ActionRow {
                FilledTonalIconButton(onClick = { console(ConsoleEvent.CancelOffer) }, modifier = Modifier.size(56.dp)) {
                    SymbolIcon(Symbol.Close, stringResource(R.string.close_offer))
                }
                val ok = s.check is OfferCheck.Ok
                Button(
                    onClick = { console(ConsoleEvent.SendOffer) },
                    enabled = ok && !busy,
                    colors = ButtonDefaults.buttonColors(containerColor = c.tertiary, contentColor = c.onTertiary),
                    modifier = Modifier.weight(1f).height(56.dp),
                ) {
                    SymbolIcon(Symbol.Send, contentDescription = null, size = 20.dp)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.send_offer, if (ok) s.draft!!.short() else ""))
                }
            }
        }
        is ConsoleState.Waiting -> {
            FigureRow(view.me.avatarUrl, s.offer)
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconLine(Symbol.HourglassTop, stringResource(R.string.waiting_for, seller), Modifier.weight(1f))
                TextButton(onClick = { console(ConsoleEvent.Withdraw) }, enabled = !busy && state.optimisticOffer == null) { Text(stringResource(R.string.withdraw)) }
            }
        }
        is ConsoleState.Agreed -> {
            FigureRow(null, s.price, icon = Symbol.Handshake)
            Notes(state)
            IconLine(
                if (s.meeting != null) Symbol.Event else Symbol.HourglassTop,
                state.meetingText ?: stringResource(R.string.waiting_proposal, seller),
                Modifier.padding(top = 12.dp),
            )
            ActionRow {
                FilledTonalIconButton(onClick = a.onSchedule, enabled = !busy, modifier = Modifier.size(56.dp)) {
                    SymbolIcon(Symbol.EditCalendar, stringResource(R.string.change_meeting))
                }
                Button(
                    onClick = { console(ConsoleEvent.ConfirmMeeting) },
                    enabled = !busy && s.meeting?.proposedBy == Party.SELLER,
                    modifier = Modifier.weight(1f).height(56.dp),
                ) {
                    SymbolIcon(Symbol.EventAvailable, contentDescription = null, size = 20.dp)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.confirm_meeting))
                }
            }
        }
        is ConsoleState.Proposing -> {
            IconLine(Symbol.Event, state.meetingText.orEmpty())
            IconLine(Symbol.HourglassTop, stringResource(R.string.waiting_agree, seller), Modifier.padding(top = 8.dp))
        }
        is ConsoleState.AtMeeting -> {
            IconLine(Symbol.LocationOn, state.meetingText.orEmpty())
            Notes(state)
            ActionRow {
                FilledTonalButton(onClick = a.onChecklist, modifier = Modifier.weight(1f).height(56.dp)) {
                    SymbolIcon(Symbol.Checklist, contentDescription = null, size = 20.dp)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.check_items, s.checked, s.total), maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Button(onClick = a.onScan, enabled = !busy && !state.scanning, modifier = Modifier.weight(1f).height(56.dp)) {
                    SymbolIcon(Symbol.QrCodeScanner, contentDescription = null, size = 20.dp)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.scan), maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
        ConsoleState.Received -> {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                (1..5).forEach { n ->
                    IconButton(onClick = { console(ConsoleEvent.Rate(n)) }, enabled = !busy, modifier = Modifier.size(48.dp)) {
                        SymbolIcon(Symbol.Star, stringResource(R.string.stars, n), filled = true, size = 36.dp, tint = c.outlineVariant)
                    }
                }
            }
            Text(stringResource(R.string.rate_person, seller), style = MaterialTheme.typography.bodySmall, color = c.onSurfaceVariant, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().padding(top = 4.dp))
            ProblemButton(a.onRecord, Modifier.align(Alignment.CenterHorizontally))
        }
        is ConsoleState.Done -> {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SymbolIcon(Symbol.CheckCircle, contentDescription = null, filled = true, tint = c.primary)
                Text(stringResource(R.string.done), style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(start = 8.dp).weight(1f))
                ProblemButton(a.onRecord)
            }
        }
    }
}

@Composable
private fun FigureRow(avatar: String?, amount: Vnd, icon: Symbol? = null) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        val c = MaterialTheme.colorScheme
        if (icon != null) {
            Box(Modifier.size(32.dp).background(c.secondaryContainer, CircleShape), Alignment.Center) {
                SymbolIcon(icon, contentDescription = null, size = 18.dp, tint = c.onSecondaryContainer)
            }
        } else {
            AsyncImage(avatar, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.size(32.dp).clip(CircleShape).background(c.secondaryContainer))
        }
        Figure(amount, Modifier.semantics { contentDescription = amount.full() })
    }
}

@Composable
private fun IconLine(icon: Symbol, text: String, modifier: Modifier = Modifier) {
    val c = MaterialTheme.colorScheme
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        SymbolIcon(icon, contentDescription = null, size = 16.dp, tint = c.onSurfaceVariant)
        Text(text, style = MaterialTheme.typography.bodySmall, color = c.onSurfaceVariant)
    }
}

@Composable
private fun Notes(state: ChatUiState) {
    Column(Modifier.padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        state.moneyNotes.forEach { MoneyNote(it) }
    }
}

@Composable
private fun ActionRow(content: @Composable RowScope.() -> Unit) {
    Row(Modifier.fillMaxWidth().padding(top = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically, content = content)
}

@Composable
private fun ProblemButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    TextButton(onClick = onClick, modifier = modifier) {
        SymbolIcon(Symbol.Report, contentDescription = null, size = 18.dp)
        Text(stringResource(R.string.problem), modifier = Modifier.padding(start = 4.dp))
    }
}
```

- [ ] **Step 4: Write the composer, the sheets, the dialog and the scanner**

`chat/Composer.kt`:

```kotlin
package vn.shopnexus.feature.deal.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.AssistChip
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringArrayResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.feature.deal.R

/** Quick replies show only while the console is folded; the composer is a pill between attach and send. */
@Composable
internal fun Composer(
    text: String,
    to: String,
    showReplies: Boolean,
    onText: (String) -> Unit,
    onSend: () -> Unit,
    onReply: (String) -> Unit,
    onAttach: () -> Unit,
    onFocus: (Boolean) -> Unit,
) {
    val c = MaterialTheme.colorScheme
    val label = stringResource(R.string.message_to, to)
    Column(Modifier.navigationBarsPadding().imePadding()) {
        if (showReplies) {
            LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
                items(stringArrayResource(R.array.quick_replies).toList()) { reply ->
                    AssistChip(onClick = { onReply(reply) }, label = { Text(reply) }, shape = CircleShape)
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onAttach) { SymbolIcon(Symbol.AddCircle, stringResource(R.string.attach)) }
            BasicTextField(
                value = text,
                onValueChange = onText,
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = c.onSurface),
                cursorBrush = SolidColor(c.primary),
                maxLines = 4,
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = 48.dp)
                    .background(c.surfaceContainerHigh, CircleShape)
                    .padding(horizontal = 20.dp, vertical = 12.dp)
                    .onFocusChanged { onFocus(it.isFocused) }
                    .semantics { contentDescription = label },
                decorationBox = { inner ->
                    Box {
                        if (text.isEmpty()) Text(stringResource(R.string.message_hint), style = MaterialTheme.typography.bodyLarge, color = c.onSurfaceVariant)
                        inner()
                    }
                },
            )
            FilledTonalIconButton(onClick = onSend, enabled = text.isNotBlank(), modifier = Modifier.padding(start = 8.dp).size(48.dp)) {
                SymbolIcon(Symbol.Send, stringResource(R.string.send))
            }
        }
    }
}
```

`chat/Sheets.kt`:

```kotlin
package vn.shopnexus.feature.deal.chat

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import java.time.Instant
import vn.shopnexus.core.designsystem.component.DeclaredMarkRow
import vn.shopnexus.core.designsystem.component.FullWidthSheet
import vn.shopnexus.core.designsystem.component.MoneyNote
import vn.shopnexus.core.designsystem.component.ShopNexusDialog
import vn.shopnexus.core.designsystem.component.SparkleLabel
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.core.designsystem.theme.Corners
import vn.shopnexus.core.domain.MoneyStep
import vn.shopnexus.core.domain.moneyNotes
import vn.shopnexus.core.model.ChatView
import vn.shopnexus.core.model.MeetPoint
import vn.shopnexus.feature.deal.R

/** "Hẹn gặp": time chips and three suggested meeting points with why each is safe. */
@Composable
internal fun ScheduleSheet(options: List<TimeOption>, points: List<MeetPoint>, onSend: (Instant, MeetPoint) -> Unit, onDismiss: () -> Unit) {
    var time by rememberSaveable { mutableIntStateOf(options.indexOfFirst { it.label.startsWith("20:00") }.coerceAtLeast(0)) }
    var place by rememberSaveable { mutableIntStateOf(0) }
    FullWidthSheet(onDismiss = onDismiss, title = stringResource(R.string.schedule_title)) {
        Text(stringResource(R.string.schedule_time), style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 8.dp))
        LazyRow(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(options.size) { i ->
                FilterChip(selected = time == i, onClick = { time = i }, label = { Text(options[i].label) }, shape = CircleShape)
            }
        }
        Text(stringResource(R.string.schedule_place), style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 16.dp))
        Column(Modifier.selectableGroup().padding(top = 4.dp)) {
            points.forEachIndexed { i, p ->
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 64.dp).selectable(place == i, role = Role.RadioButton) { place = i },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RadioButton(selected = place == i, onClick = null)
                    Column(Modifier.padding(start = 16.dp)) {
                        Text(p.name, style = MaterialTheme.typography.bodyLarge)
                        Text(p.why, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
        Button(
            onClick = { options.getOrNull(time)?.let { t -> points.getOrNull(place)?.let { onSend(t.at, it) } } },
            enabled = options.isNotEmpty() && points.isNotEmpty(),
            modifier = Modifier.padding(top = 16.dp).fillMaxWidth().height(56.dp),
        ) {
            SymbolIcon(Symbol.Send, contentDescription = null, size = 20.dp)
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.schedule_send))
        }
    }
}

/** "Danh sách kiểm": the checks the model wrote for this item, then the declared marks and their sentence. */
@Composable
internal fun ChecklistSheet(view: ChatView, onCheck: (String, Boolean) -> Unit, onDismiss: () -> Unit) {
    FullWidthSheet(onDismiss = onDismiss, title = stringResource(R.string.checklist_title)) {
        view.deal.checklist.forEach { item ->
            Row(
                Modifier.fillMaxWidth().heightIn(min = 56.dp).toggleable(item.checked, role = Role.Checkbox) { onCheck(item.id, it) },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                SymbolIcon(Symbol.of(item.icon) ?: Symbol.Check, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(item.text, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f).padding(horizontal = 16.dp))
                Checkbox(checked = item.checked, onCheckedChange = null)
            }
        }
        if (view.declaredMarks.isNotEmpty()) {
            Text(stringResource(R.string.checklist_declared), style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 16.dp, bottom = 8.dp))
            view.declaredMarks.forEach { DeclaredMarkRow(it, it.text, onOpen = {}) }
        }
        Column(Modifier.padding(top = 12.dp)) {
            moneyNotes(MoneyStep.HANDOVER_CHECKLIST, view.deal.agreedPrice ?: view.deal.listedPrice).forEach { MoneyNote(it) }
        }
    }
}

/** Asked once before scanning with checks left: after paying there is no way back. */
@Composable
internal fun UncheckedDialog(left: Int, onScan: () -> Unit, onCheck: () -> Unit) {
    ShopNexusDialog(
        title = stringResource(R.string.unchecked_title),
        text = stringResource(R.string.unchecked_text, left),
        confirm = stringResource(R.string.unchecked_scan),
        onConfirm = onScan,
        dismiss = stringResource(R.string.unchecked_check),
        onDismiss = onCheck,
    )
}

/** "Ghi nhận sự cố": a photo from the Photo Picker, what happened, the declared marks, and who decides. */
@Composable
internal fun RecordSheet(draft: RecordDraft, view: ChatView, pending: Boolean, onEvent: (ChatEvent) -> Unit) {
    val c = MaterialTheme.colorScheme
    val whatLabel = stringResource(R.string.record_what)
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri: Uri? ->
        uri?.let { onEvent(ChatEvent.RecordPhoto(it.toString())) }
    }
    FullWidthSheet(onDismiss = { onEvent(ChatEvent.CloseRecord) }, title = stringResource(R.string.record_title)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (draft.photo != null) {
                AsyncImage(draft.photo, contentDescription = stringResource(R.string.record_photo), contentScale = ContentScale.Crop, modifier = Modifier.size(80.dp).clip(Corners.Large).background(c.surfaceContainerHigh))
            }
            Column(
                Modifier.size(80.dp).clip(Corners.Large).background(c.surfaceContainer)
                    .clickable(onClickLabel = stringResource(R.string.record_add_photo)) { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) { SymbolIcon(Symbol.AddAPhoto, stringResource(R.string.record_add_photo), size = 26.dp, tint = c.onSurfaceVariant) }
        }
        Column(Modifier.padding(top = 12.dp).fillMaxWidth().background(c.surfaceContainerHigh, Corners.Large).padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 10.dp)) {
            Text(stringResource(R.string.record_what), style = MaterialTheme.typography.bodySmall, color = c.onSurfaceVariant)
            BasicTextField(
                value = draft.text,
                onValueChange = { onEvent(ChatEvent.RecordText(it)) },
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = c.onSurface),
                cursorBrush = SolidColor(c.primary),
                minLines = 3,
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = whatLabel },
            )
        }
        if (view.declaredMarks.isNotEmpty()) {
            SparkleLabel(stringResource(R.string.record_declared, view.declaredMarks.joinToString { it.text }), modifier = Modifier.padding(top = 12.dp))
        }
        Row(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SymbolIcon(Symbol.Gavel, contentDescription = null, size = 18.dp, tint = c.onSurfaceVariant)
            Text(stringResource(R.string.record_who_decides, view.counterpart.name), style = MaterialTheme.typography.bodyMedium, color = c.onSurfaceVariant)
        }
        Button(onClick = { onEvent(ChatEvent.SendRecord) }, enabled = draft.canSend && !pending, modifier = Modifier.padding(top = 24.dp).fillMaxWidth().height(56.dp)) {
            SymbolIcon(Symbol.Send, contentDescription = null, size = 20.dp)
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.record_send))
        }
    }
}
```

`chat/Scanner.kt`:

```kotlin
package vn.shopnexus.feature.deal.chat

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import coil3.compose.AsyncImage
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.feature.deal.R
import vn.shopnexus.core.designsystem.R as DesignR

/** Full-screen black over the seller's photo at 40 %: what the scan records, a 240 dp frame, a moving line. It moves no money. */
@Composable
internal fun ScannerOverlay(person: String, backdrop: String?, animate: Boolean, onClose: () -> Unit) {
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            AsyncImage(backdrop, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize().alpha(0.4f))
            IconButton(onClick = onClose, modifier = Modifier.statusBarsPadding().padding(4.dp)) {
                SymbolIcon(Symbol.Close, stringResource(DesignR.string.close), tint = Color.White)
            }
            Column(Modifier.fillMaxWidth().statusBarsPadding().padding(top = 104.dp, start = 32.dp, end = 32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(stringResource(R.string.scanner_title, person), style = MaterialTheme.typography.titleLarge, color = Color.White, textAlign = TextAlign.Center)
                Text(stringResource(R.string.scanner_text), style = MaterialTheme.typography.bodyMedium, color = Color.White.copy(alpha = 0.8f), textAlign = TextAlign.Center, modifier = Modifier.padding(top = 4.dp))
                Box(Modifier.padding(top = 40.dp).size(240.dp).border(4.dp, Color.White, RoundedCornerShape(20.dp))) {
                    val y = if (animate) {
                        rememberInfiniteTransition(label = "scan").animateFloat(0f, 204f, infiniteRepeatable(tween(1_100), RepeatMode.Reverse), label = "line").value
                    } else 0f
                    Box(Modifier.offset(y = (16 + y).dp).padding(horizontal = 16.dp).fillMaxWidth().height(2.dp).background(Color.White, CircleShape))
                }
            }
        }
    }
}
```

The mockup draws only the four corners of the frame; a full white border is the stage 1 frame, and CameraX in stage 3 replaces the overlay with the camera preview.

- [ ] **Step 5: Write the screen and the installer**

`chat/ChatScreen.kt`:

```kotlin
package vn.shopnexus.feature.deal.chat

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation3.runtime.NavKey
import coil3.compose.AsyncImage
import vn.shopnexus.core.designsystem.component.ErrorState
import vn.shopnexus.core.designsystem.component.LocalDebugTrigger
import vn.shopnexus.core.designsystem.component.MessageEffect
import vn.shopnexus.core.designsystem.component.ShopNexusLoading
import vn.shopnexus.core.designsystem.component.ShopNexusTopBar
import vn.shopnexus.core.designsystem.component.rememberReducedMotion
import vn.shopnexus.core.designsystem.icon.Symbol
import vn.shopnexus.core.designsystem.icon.SymbolIcon
import vn.shopnexus.core.designsystem.theme.Corners
import vn.shopnexus.core.domain.ConsoleEvent
import vn.shopnexus.core.domain.ConsoleState
import vn.shopnexus.core.domain.DealConsole
import vn.shopnexus.core.model.ChatView
import vn.shopnexus.core.navigation.ChatRoute
import vn.shopnexus.core.navigation.ListingRoute
import vn.shopnexus.core.navigation.Navigator
import vn.shopnexus.core.navigation.PlaceholderRoute
import vn.shopnexus.feature.deal.R
import vn.shopnexus.core.designsystem.R as DesignR

@Composable
internal fun ChatEntry(route: ChatRoute, navigator: Navigator) {
    val viewModel = hiltViewModel<ChatViewModel, ChatViewModel.Factory>(creationCallback = { it.create(route) })
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    MessageEffect(viewModel.messages, snackbar)
    ChatScreen(state, viewModel::onEvent, navigator::push, navigator::back, snackbar, animate = !rememberReducedMotion())
}

@Composable
fun ChatScreen(
    state: ChatUiState,
    onEvent: (ChatEvent) -> Unit,
    onNavigate: (NavKey) -> Unit,
    onBack: () -> Unit,
    snackbar: SnackbarHostState,
    modifier: Modifier = Modifier,
    animate: Boolean = true,
) {
    val view = (state.content as? ChatContent.Ready)?.view
    var typingFocus by remember { mutableStateOf(false) }
    var foldedByHand by rememberSaveable { mutableStateOf(false) }
    var schedule by rememberSaveable { mutableStateOf(false) }
    var checklist by rememberSaveable { mutableStateOf(false) }
    var unchecked by rememberSaveable { mutableStateOf(false) }
    val folded = foldedByHand || typingFocus || state.composer.isNotEmpty()
    Scaffold(
        modifier = modifier,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            ShopNexusTopBar(
                title = { if (view != null) ChatTitle(view) { onNavigate(ListingRoute(view.listing.id.value)) } },
                onBack = onBack,
            )
        },
    ) { padding ->
        when (state.content) {
            ChatContent.Loading -> Box(Modifier.padding(padding).fillMaxSize(), Alignment.Center) { ShopNexusLoading() }
            ChatContent.Failed -> ErrorState(stringResource(R.string.chat_failed), { onEvent(ChatEvent.Retry) }, Modifier.padding(padding))
            ChatContent.Missing -> Column(Modifier.padding(padding).fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                Text(stringResource(R.string.chat_missing), style = MaterialTheme.typography.bodyLarge)
                Button(onClick = onBack, modifier = Modifier.padding(top = 16.dp).height(48.dp)) { Text(stringResource(DesignR.string.back)) }
            }
            is ChatContent.Ready -> Column(Modifier.padding(padding).fillMaxSize()) {
                val v = state.content.view
                ChatThread(v, state.optimisticOffer, state.typing, animate, { onEvent(ChatEvent.ConfirmRefund(it)) }, rememberLazyListState(), Modifier.weight(1f))
                DealConsoleCard(
                    state = state,
                    view = v,
                    folded = folded,
                    onFold = { foldedByHand = it },
                    actions = ConsoleActions(
                        onEvent = onEvent,
                        onSchedule = { schedule = true },
                        onChecklist = { checklist = true },
                        onScan = { if (DealConsole.needsCheckWarning(state.console!!)) unchecked = true else onEvent(ChatEvent.StartScan) },
                        onRecord = { onEvent(ChatEvent.OpenRecord) },
                    ),
                )
                Composer(
                    text = state.composer,
                    to = v.counterpart.name,
                    showReplies = folded,
                    onText = { onEvent(ChatEvent.Compose(it)) },
                    onSend = { onEvent(ChatEvent.SendMessage) },
                    onReply = { onEvent(ChatEvent.Reply(it)) },
                    onAttach = { onNavigate(PlaceholderRoute(3, "Gửi ảnh")) },
                    onFocus = { typingFocus = it },
                )
                if (schedule) {
                    ScheduleSheet(state.timeOptions, v.deal.meetPoints, onSend = { at, place ->
                        schedule = false
                        onEvent(ChatEvent.Console(ConsoleEvent.Propose(at, place)))
                    }, onDismiss = { schedule = false })
                }
                if (checklist) ChecklistSheet(v, { id, on -> onEvent(ChatEvent.Console(ConsoleEvent.Check(id, on))) }, { checklist = false })
                if (unchecked) {
                    val left = (state.console as? ConsoleState.AtMeeting)?.let { it.total - it.checked } ?: 0
                    UncheckedDialog(left, onScan = { unchecked = false; onEvent(ChatEvent.StartScan) }, onCheck = { unchecked = false; checklist = true })
                }
                state.record?.let { RecordSheet(it, v, state.pending, onEvent) }
                if (state.scanning) ScannerOverlay(v.counterpart.name, v.counterpart.avatarUrl, animate) { onEvent(ChatEvent.CancelScan) }
            }
        }
    }
}

/** The listing as the subject: a 40 dp thumbnail with the seller's avatar on its corner, the title, the seller's name. A long press opens the debug panel. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ChatTitle(view: ChatView, onOpen: () -> Unit) {
    val c = MaterialTheme.colorScheme
    val label = stringResource(R.string.open_listing, view.listing.title)
    Row(
        Modifier.combinedClickable(onClickLabel = label, onClick = onOpen, onLongClick = LocalDebugTrigger.current).semantics { contentDescription = label },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(44.dp)) {
            AsyncImage(view.listing.photoUrl, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.size(40.dp).clip(Corners.Medium).background(c.surfaceContainerHigh))
            AsyncImage(
                view.counterpart.avatarUrl, contentDescription = null, contentScale = ContentScale.Crop,
                modifier = Modifier.align(Alignment.BottomEnd).offset(x = 2.dp, y = 2.dp).size(20.dp).clip(CircleShape).background(c.surface).padding(1.dp).clip(CircleShape),
            )
        }
        Column(Modifier.padding(start = 12.dp)) {
            Text(view.listing.title, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(view.counterpart.name, style = MaterialTheme.typography.bodySmall, color = c.onSurfaceVariant)
                if (view.counterpart.verified) SymbolIcon(Symbol.Verified, contentDescription = null, filled = true, size = 14.dp, tint = c.primary)
            }
        }
    }
}
```

`app2/feature/deal/src/main/kotlin/vn/shopnexus/feature/deal/DealInstaller.kt`:

```kotlin
package vn.shopnexus.feature.deal

import androidx.navigation3.runtime.EntryProviderScope
import androidx.navigation3.runtime.NavKey
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dagger.multibindings.IntoSet
import javax.inject.Inject
import vn.shopnexus.core.navigation.ChatRoute
import vn.shopnexus.core.navigation.EntryInstaller
import vn.shopnexus.core.navigation.Navigator
import vn.shopnexus.feature.deal.chat.ChatEntry

class DealInstaller @Inject constructor() : EntryInstaller {
    override fun install(scope: EntryProviderScope<NavKey>, navigator: Navigator) = with(scope) {
        entry<ChatRoute> { route -> ChatEntry(route, navigator) }
    }
}

@Module
@InstallIn(SingletonComponent::class)
abstract class DealModule {
    @Binds @IntoSet abstract fun installer(impl: DealInstaller): EntryInstaller
}
```

- [ ] **Step 6: Run the tests and record the screenshots**

Run: `./gradlew :feature:deal:testDebugUnitTest`
Expected: PASS, 24 tests.

Run: `./gradlew :feature:deal:recordRoborazziDebug`. Open each `chat-*.png` next to `tmp/chat.html` stepped to the same state (the mockup's debug strip or its buttons move it). For every state check the body and actions in the table of the Chat section of the spec: Countered with the seller's avatar, 10.600.000, "Rẻ hơn 15%" in terracotta and "23 giờ", "Trả giá" tonal terracotta, "Đồng ý" filled; Offering with the stepper at 10.500.000, "−100.000 ₫", three chips with the balance icon on 10,5 tr and "Gửi 10,5 tr" in terracotta; Waiting with your avatar and "Rút lại"; Agreed with the handshake, both money sentences, "19:00 hôm nay · Sảnh Landmark 81" and "Đồng ý hẹn"; Proposing; Meeting with "Kiểm máy 0/6" and "Quét mã"; Received with five stars; Done with "Đã xong" and the record card. The agreed milestone in the thread is the pale peach cookie. Then `./gradlew :feature:deal:verifyRoborazziDebug`.

- [ ] **Step 7: Commit**

```bash
git add feature/deal
git commit -m "feat(deal): add the Chat screen with the console, sheets, scanner and record

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```


---

### Task 23: The debug panel

A sheet in debug builds only, opened by a long press on a pushed screen's title or on Home's location pill. It jumps the deal to any console state, resets the fake world, speeds the seller up, injects failures, and switches the theme.

**Files:**
- Create: `app2/core/data/src/main/kotlin/vn/shopnexus/core/data/fake/DebugControls.kt`
- Modify: `app2/core/data/src/main/kotlin/vn/shopnexus/core/data/fake/Simulator.kt` (make `cancel` public as `stop`)
- Test: `app2/core/data/src/test/kotlin/vn/shopnexus/core/data/fake/DebugControlsTest.kt`
- Modify: `app2/app/src/debug/kotlin/vn/shopnexus/app2/DebugHost.kt`
- Create: `app2/app/src/debug/res/values/strings.xml`
- Test: `app2/app/src/testDebug/kotlin/vn/shopnexus/app2/DebugPanelTest.kt`

**Interfaces:**
- Consumes: `FakeWorld`, `Simulator`, `FailurePolicy` (Tasks 11–12); `DealConsole` (Task 9); `ThemeSettings` (Task 18); `LocalDebugTrigger` (Task 16).
- Produces:
  ```kotlin
  enum class ConsoleTarget { COUNTERED, WAITING, AGREED, PROPOSING, MEETING, RECEIVED, DONE }
  internal fun dealAt(start: Deal, target: ConsoleTarget, now: Instant, zone: ZoneId): Deal
  class DebugControls { var fast: Boolean; var failing: Boolean; fun reset(); fun jump(target: ConsoleTarget, id: DealId = DealId("d-kiet")) }
  fun Simulator.stop(id: DealId)   // cancels a pending reply and the typing dots
  ```

- [ ] **Step 1: Write the failing controls test**

`DebugControlsTest.kt`:

```kotlin
package vn.shopnexus.core.data.fake

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.test.runTest
import org.junit.Test
import vn.shopnexus.core.domain.ConsoleDraft
import vn.shopnexus.core.domain.ConsoleState
import vn.shopnexus.core.domain.DealConsole
import vn.shopnexus.core.domain.VN_ZONE
import vn.shopnexus.core.model.DealId
import vn.shopnexus.core.testing.SchedulerClock

class DebugControlsTest {
    private val idle = ConsoleDraft(editing = false, amount = null)

    @Test
    fun everyTargetLandsOnItsConsoleState() = runTest {
        val world = FakeWorld()
        val clock = SchedulerClock(testScheduler)
        val controls = DebugControls(world, Simulator(world, clock, backgroundScope, VN_ZONE), FailurePolicy(), clock, VN_ZONE)
        val expected = mapOf(
            ConsoleTarget.COUNTERED to ConsoleState.Countered::class,
            ConsoleTarget.WAITING to ConsoleState.Waiting::class,
            ConsoleTarget.AGREED to ConsoleState.Agreed::class,
            ConsoleTarget.PROPOSING to ConsoleState.Proposing::class,
            ConsoleTarget.MEETING to ConsoleState.AtMeeting::class,
            ConsoleTarget.RECEIVED to ConsoleState.Received::class,
            ConsoleTarget.DONE to ConsoleState.Done::class,
        )
        expected.forEach { (target, kind) ->
            controls.jump(target)
            val deal = world.value.chats.getValue(DealId("d-kiet")).deal
            assertThat(DealConsole.state(deal, idle)::class).isEqualTo(kind)
        }
    }

    @Test
    fun switchesSetTheSimulatorAndFailuresAndResetRestores() = runTest {
        val world = FakeWorld()
        val clock = SchedulerClock(testScheduler)
        val simulator = Simulator(world, clock, backgroundScope, VN_ZONE)
        val failures = FailurePolicy()
        val controls = DebugControls(world, simulator, failures, clock, VN_ZONE)
        controls.fast = true
        controls.failing = true
        assertThat(simulator.speed).isEqualTo(4.0)
        assertThat(failures.rate).isEqualTo(0.5)
        controls.jump(ConsoleTarget.DONE)
        controls.reset()
        assertThat(world.value).isEqualTo(FakeWorld.initial())
    }
}
```

Run: `./gradlew :core:data:testDebugUnitTest --tests "*DebugControlsTest*"`
Expected: FAIL, `Unresolved reference 'DebugControls'`.

- [ ] **Step 2: Write the controls**

In `Simulator.kt`, rename `private fun cancel(id: DealId)` to `fun stop(id: DealId)` and change its one call in `onCommand` (`DealCommand.WithdrawOffer -> stop(id)`).

`DebugControls.kt`:

```kotlin
package vn.shopnexus.core.data.fake

import java.time.Clock
import java.time.Instant
import java.time.ZoneId
import javax.inject.Inject
import javax.inject.Singleton
import vn.shopnexus.core.domain.meetingLabel
import vn.shopnexus.core.domain.todayAt
import vn.shopnexus.core.model.Deal
import vn.shopnexus.core.model.DealId
import vn.shopnexus.core.model.DealStage
import vn.shopnexus.core.model.Meeting
import vn.shopnexus.core.model.MilestoneKind
import vn.shopnexus.core.model.Offer
import vn.shopnexus.core.model.OfferStatus
import vn.shopnexus.core.model.Party
import vn.shopnexus.core.model.ThreadItem
import vn.shopnexus.core.model.Vnd

/** The console states the panel can jump to. Offering is the buyer's own draft, so it is not one of them. */
enum class ConsoleTarget { COUNTERED, WAITING, AGREED, PROPOSING, MEETING, RECEIVED, DONE }

/** The fixture deal moved to [target], with the thread items a real walk would have left. */
internal fun dealAt(start: Deal, target: ConsoleTarget, now: Instant, zone: ZoneId): Deal {
    if (target == ConsoleTarget.COUNTERED) return start
    val counter = start.openCounter!!.amount
    if (target == ConsoleTarget.WAITING) {
        val offer = Vnd(counter.amount - 100_000)
        return start.copy(
            offers = start.offers + Offer(Party.BUYER, offer, now, OfferStatus.OPEN),
            thread = start.thread + ThreadItem.PriceMove(Party.BUYER, offer, accepted = false, at = now),
        )
    }
    val tonight = Meeting(todayAt(19, 0, now, zone), start.meetPoints.first(), Party.SELLER, confirmed = false)
    val agreed = start.copy(
        stage = DealStage.ARRANGE,
        agreedPrice = counter,
        meeting = tonight,
        offers = start.offers.map { if (it.status == OfferStatus.OPEN) it.copy(status = OfferStatus.ACCEPTED) else it },
        thread = start.thread + ThreadItem.PriceMove(Party.BUYER, counter, accepted = true, at = now) + ThreadItem.Milestone(MilestoneKind.AGREED, now),
    )
    if (target == ConsoleTarget.AGREED) return agreed
    if (target == ConsoleTarget.PROPOSING) {
        return agreed.copy(meeting = Meeting(todayAt(20, 0, now, zone), start.meetPoints[1], Party.BUYER, confirmed = false))
    }
    val confirmed = tonight.copy(confirmed = true)
    val meeting = agreed.copy(
        stage = DealStage.HANDOVER,
        meeting = confirmed,
        thread = agreed.thread + ThreadItem.Event("event_available", "Đã hẹn ${meetingLabel(confirmed.at, now, zone)} · ${confirmed.place.name}", now),
    )
    if (target == ConsoleTarget.MEETING) return meeting
    val received = meeting.copy(stage = DealStage.RATE, handedOverAt = now, thread = meeting.thread + ThreadItem.Milestone(MilestoneKind.HANDED_OVER, now))
    if (target == ConsoleTarget.RECEIVED) return received
    return received.copy(
        stage = DealStage.DONE,
        rating = 5,
        thread = received.thread + ThreadItem.Event("star", "5 sao", now) + ThreadItem.Milestone(MilestoneKind.RATED, now),
    )
}

/** What the debug panel changes. Debug builds only reach it; release builds never show the panel. */
@Singleton
class DebugControls @Inject constructor(
    private val world: FakeWorld,
    private val simulator: Simulator,
    private val failures: FailurePolicy,
    private val clock: Clock,
    private val zone: ZoneId,
) {
    var fast: Boolean
        get() = simulator.speed > 1.0
        set(on) { simulator.speed = if (on) 4.0 else 1.0 }

    var failing: Boolean
        get() = failures.rate > 0.0
        set(on) { failures.rate = if (on) 0.5 else 0.0 }

    fun reset() {
        world.value.chats.keys.forEach(simulator::stop)
        world.reset()
    }

    fun jump(target: ConsoleTarget, id: DealId = DealId("d-kiet")) {
        simulator.stop(id)
        val start = FakeWorld.initial().chats.getValue(id)
        world.update { s -> s.copy(chats = s.chats + (id to start.copy(deal = dealAt(start.deal, target, clock.instant(), zone)))) }
    }
}
```

Run: `./gradlew :core:data:testDebugUnitTest`
Expected: PASS, 23 tests.

- [ ] **Step 3: Write the panel**

`app2/app/src/debug/res/values/strings.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="debug_title">Bảng gỡ lỗi</string>
    <string name="debug_jump">Chuyển giao dịch với Tuấn Kiệt tới</string>
    <string name="debug_countered">Người bán trả giá</string>
    <string name="debug_waiting">Đã gửi đề nghị</string>
    <string name="debug_agreed">Đã chốt giá</string>
    <string name="debug_proposing">Đang đề xuất giờ</string>
    <string name="debug_meeting">Đã hẹn gặp</string>
    <string name="debug_received">Đã nhận máy</string>
    <string name="debug_done">Đã đánh giá</string>
    <string name="debug_fast">Người bán trả lời nhanh gấp 4</string>
    <string name="debug_failing">Lỗi mạng giả, một nửa số lần gọi</string>
    <string name="debug_dynamic">Màu theo hình nền</string>
    <string name="debug_theme">Giao diện</string>
    <string name="debug_theme_system">Theo hệ thống</string>
    <string name="debug_theme_light">Sáng</string>
    <string name="debug_theme_dark">Tối</string>
    <string name="debug_reset">Đặt lại dữ liệu mẫu</string>
</resources>
```

`app2/app/src/debug/kotlin/vn/shopnexus/app2/DebugHost.kt`:

```kotlin
package vn.shopnexus.app2

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AssistChip
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.launch
import vn.shopnexus.core.data.fake.ConsoleTarget
import vn.shopnexus.core.data.fake.DebugControls
import vn.shopnexus.core.designsystem.component.FullWidthSheet
import vn.shopnexus.core.designsystem.component.GroupRow
import vn.shopnexus.core.designsystem.component.GroupedList
import vn.shopnexus.core.designsystem.component.LocalDebugTrigger
import vn.shopnexus.core.designsystem.theme.ThemeMode

@EntryPoint
@InstallIn(SingletonComponent::class)
interface DebugEntryPoint {
    fun controls(): DebugControls
    fun settings(): ThemeSettings
}

/** Debug builds: a long press on a title or on Home's location pill opens the panel. */
@Composable
fun DebugHost(content: @Composable () -> Unit) {
    var open by rememberSaveable { mutableStateOf(false) }
    CompositionLocalProvider(LocalDebugTrigger provides { open = true }) { content() }
    if (open) DebugPanel(onDismiss = { open = false })
}

@OptIn(ExperimentalLayoutApi::class, ExperimentalMaterial3Api::class)
@Composable
private fun DebugPanel(onDismiss: () -> Unit) {
    val context = LocalContext.current
    val entry = remember { EntryPointAccessors.fromApplication(context, DebugEntryPoint::class.java) }
    val controls = entry.controls()
    val settings = entry.settings()
    val scope = rememberCoroutineScope()
    var fast by remember { mutableStateOf(controls.fast) }
    var failing by remember { mutableStateOf(controls.failing) }
    val mode by settings.mode.collectAsState(ThemeMode.SYSTEM)
    val dynamic by settings.dynamicColor.collectAsState(false)
    val targets = listOf(
        ConsoleTarget.COUNTERED to R.string.debug_countered, ConsoleTarget.WAITING to R.string.debug_waiting,
        ConsoleTarget.AGREED to R.string.debug_agreed, ConsoleTarget.PROPOSING to R.string.debug_proposing,
        ConsoleTarget.MEETING to R.string.debug_meeting, ConsoleTarget.RECEIVED to R.string.debug_received,
        ConsoleTarget.DONE to R.string.debug_done,
    )
    FullWidthSheet(onDismiss = onDismiss, title = stringResource(R.string.debug_title)) {
        Text(stringResource(R.string.debug_jump), style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 8.dp))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            targets.forEach { (target, label) ->
                AssistChip(onClick = { controls.jump(target); onDismiss() }, label = { Text(stringResource(label)) })
            }
        }
        GroupedList(Modifier.padding(top = 16.dp)) {
            row("fast") { GroupRow(stringResource(R.string.debug_fast), trailing = { Switch(fast, { fast = it; controls.fast = it }) }) }
            row("failing") { GroupRow(stringResource(R.string.debug_failing), trailing = { Switch(failing, { failing = it; controls.failing = it }) }) }
            row("dynamic") { GroupRow(stringResource(R.string.debug_dynamic), trailing = { Switch(dynamic, { on -> scope.launch { settings.setDynamicColor(on) } }) }) }
        }
        Text(stringResource(R.string.debug_theme), style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 16.dp, bottom = 8.dp))
        val modes = listOf(ThemeMode.SYSTEM to R.string.debug_theme_system, ThemeMode.LIGHT to R.string.debug_theme_light, ThemeMode.DARK to R.string.debug_theme_dark)
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            modes.forEachIndexed { i, (m, label) ->
                SegmentedButton(
                    selected = mode == m,
                    onClick = { scope.launch { settings.setMode(m) } },
                    shape = SegmentedButtonDefaults.itemShape(i, modes.size),
                ) { Text(stringResource(label)) }
            }
        }
        OutlinedButton(onClick = { controls.reset(); onDismiss() }, modifier = Modifier.padding(top = 16.dp).fillMaxWidth().height(48.dp)) {
            Text(stringResource(R.string.debug_reset))
        }
    }
}
```

- [ ] **Step 4: Write the panel test**

`app2/app/src/testDebug/kotlin/vn/shopnexus/app2/DebugPanelTest.kt`:

```kotlin
package vn.shopnexus.app2

import androidx.compose.foundation.layout.Box
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import com.google.common.truth.Truth.assertThat
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import dagger.hilt.android.testing.HiltTestApplication
import javax.inject.Inject
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import vn.shopnexus.core.data.fake.FakeWorld
import vn.shopnexus.core.designsystem.component.debugTrigger
import vn.shopnexus.core.designsystem.theme.ShopNexusTheme
import vn.shopnexus.core.model.DealId
import vn.shopnexus.core.model.DealStage

@HiltAndroidTest
@RunWith(RobolectricTestRunner::class)
@Config(application = HiltTestApplication::class)
class DebugPanelTest {
    @get:Rule(order = 0) val hilt = HiltAndroidRule(this)
    @get:Rule(order = 1) val compose = createComposeRule()
    @Inject lateinit var world: FakeWorld

    @Before fun inject() = hilt.inject()

    @Test
    fun aLongPressOpensThePanelAndAJumpMovesTheDeal() {
        compose.setContent { ShopNexusTheme { DebugHost { Box { Text("Tuấn Kiệt", Modifier.debugTrigger()) } } } }
        compose.onNodeWithText("Tuấn Kiệt").performTouchInput { longClick() }
        compose.onNodeWithText("Đã hẹn gặp").performClick()
        assertThat(world.value.chats.getValue(DealId("d-kiet")).deal.stage).isEqualTo(DealStage.HANDOVER)
    }
}
```

Run: `./gradlew :app:testDebugUnitTest`
Expected: PASS, 7 tests.

- [ ] **Step 5: Walk the panel on the emulator**

`./gradlew :app:installDebug`. Long-press the location pill on Home: the panel opens. Turn on "Lỗi mạng giả", pull to refresh until the snackbar says "Chưa tải được. Thử lại"; open the chat and tap "Đồng ý" until "Chưa gửi được. Thử lại" shows and the console stays on the counter. Turn it off. Jump to "Đã hẹn gặp" from the chat title's long press: the console shows the meeting. Switch "Tối" and "Màu theo hình nền": the whole app follows, and listing photos keep their colours. "Đặt lại dữ liệu mẫu" puts the deal back on the counter. Run `./gradlew :app:assembleRelease` and check the release APK has no panel: a long press on the location pill does nothing there.

- [ ] **Step 6: Commit**

```bash
git add core/data app
git commit -m "feat(app): add the debug panel for deal states, failures, speed and theme

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 24: End-to-end slice test and CI

A Robolectric test walks the whole slice through the real app, a README says how to build and run it, and GitHub Actions runs every check on each pull request. The task ends with the acceptance checks of the spec.

**Files:**
- Test: `app2/app/src/test/kotlin/vn/shopnexus/app2/SliceTest.kt`
- Create: `app2/README.md`
- Create: `app2/.github/workflows/check.yml`
- Create: `app2/tools/review_page.py`

**Interfaces:**
- Consumes: everything above.
- Produces: `./gradlew check verifyRoborazziDebug` green on a clean checkout; `build/review/index.html` with every screenshot next to its mockup.

- [ ] **Step 1: Write the slice test**

`SliceTest.kt`:

```kotlin
package vn.shopnexus.app2

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Looper
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import com.google.common.truth.Truth.assertThat
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import dagger.hilt.android.testing.HiltTestApplication
import java.time.Duration
import javax.inject.Inject
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import vn.shopnexus.core.data.fake.FailurePolicy
import vn.shopnexus.core.data.fake.FakeWorld
import vn.shopnexus.core.data.fake.Simulator
import vn.shopnexus.core.model.DealId
import vn.shopnexus.core.model.RecordStatus
import vn.shopnexus.core.testing.fakeImages

/** Home → Listing detail → offer → agree → meeting → checks → scan → rating → record, through the real app and the fakes. */
@OptIn(ExperimentalTestApi::class)
@HiltAndroidTest
@RunWith(RobolectricTestRunner::class)
@Config(application = HiltTestApplication::class, qualifiers = "w412dp-h915dp-xhdpi")
class SliceTest {
    @get:Rule(order = 0) val hilt = HiltAndroidRule(this)
    @get:Rule(order = 1) val compose = createEmptyComposeRule()
    @Inject lateinit var simulator: Simulator
    @Inject lateinit var failures: FailurePolicy
    @Inject lateinit var world: FakeWorld

    @Before
    fun setUp() {
        hilt.inject()
        simulator.speed = 20.0
        failures.latencyMillis = 0
        fakeImages()
    }

    private fun waitFor(text: String) = compose.waitUntil(5_000) { compose.onAllNodes(hasText(text)).fetchSemanticsNodes().isNotEmpty() }

    /** Robolectric's main looper keeps its own clock; delays posted on it (the fake scanner) need it moved. */
    private fun passMainLooperTime(millis: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(millis))

    @Test
    fun walksTheWholeSlice() {
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        waitFor("Gần bạn")

        compose.onNodeWithTag("home-list").performScrollToNode(hasContentDescription("Xem iPhone 13 Pro 128GB, Xanh Sierra, pin 88%"))
        compose.onNodeWithContentDescription("Xem iPhone 13 Pro 128GB, Xanh Sierra, pin 88%").performClick()
        waitFor("Trả giá")

        compose.onNodeWithText("Trả giá").performClick()
        compose.onNode(hasText("Gửi 10,5 tr") and isEnabled()).performClick()
        waitFor("Đã trả 10,5 tr")
        compose.onNodeWithText("Đã trả 10,5 tr").performClick()

        waitFor("Rút lại")
        compose.waitUntil(5_000) { compose.onAllNodes(hasText("Đồng ý hẹn") and isEnabled()).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Đồng ý hẹn").performClick()

        waitFor("Kiểm máy 0/6")
        compose.onNodeWithText("Kiểm máy 0/6").performClick()
        listOf(
            "Face ID mở được máy", "Pin từ 88% (Cài đặt › Pin)", "Đã thoát iCloud, tắt Tìm iPhone",
            "IMEI trong máy trùng hộp", "Camera, loa, mic chạy tốt", "Màn hình không điểm chết",
        ).forEach { compose.onNodeWithText(it).performClick() }
        compose.onNodeWithContentDescription("Đóng").performClick()
        waitFor("Kiểm máy 6/6")

        compose.onNodeWithText("Quét mã").performClick()
        passMainLooperTime(2_000)
        waitFor("Giao dịch đã ghi nhận")
        compose.onNodeWithContentDescription("5 sao").performClick()
        waitFor("Cảm ơn bạn")

        compose.onNodeWithText("Máy có vấn đề?").performClick()
        compose.onNodeWithContentDescription("Thêm ảnh").performClick()
        scenario.onActivity { activity ->
            val started = shadowOf(activity).nextStartedActivityForResult
            shadowOf(activity).receiveResult(started.intent, Activity.RESULT_OK, Intent().setData(Uri.parse("content://media/picker/0/1")))
        }
        compose.onNodeWithContentDescription("Chuyện gì xảy ra").performTextInput("Mặt lưng có vết nứt nhỏ")
        compose.onNodeWithText("Gửi ghi nhận").performClick()
        waitFor("Đã nhận tiền hoàn")
        compose.onNodeWithText("Đã nhận tiền hoàn").performClick()

        val record = world.value.chats.getValue(DealId("d-kiet")).deal.records.single()
        assertThat(record.status).isEqualTo(RecordStatus.REFUNDED)
        assertThat(record.refundConfirmed).isTrue()
        scenario.close()
    }
}
```

The Photo Picker is a system activity; `receiveResult` hands the result back the way Android does, so the record goes through the real launcher callback.

Run: `./gradlew :app:testDebugUnitTest --tests "*SliceTest*"`
Expected: PASS. A failure names the text it waited for; fix the screen or the fake that left it out, not the test.

- [ ] **Step 2: Write the review page**

`app2/tools/review_page.py`:

```python
"""Write build/review/index.html: every screenshot of the app next to the mockup it follows.

Run from app2/: python3 tools/review_page.py, then open build/review/index.html.
"""
import html
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "build/review/index.html"
MOCKUP = {"home": "home", "detail": "detail", "chat": "chat"}


def mockup_for(name):
    return next((f"../../.superdesign/tmp/{page}.html" for prefix, page in MOCKUP.items() if name.startswith(prefix)), None)


def main():
    shots = sorted(p for p in ROOT.glob("*/**/src/test/screenshots/*.png") if "build" not in p.parts)
    rows = []
    for shot in shots:
        mock = mockup_for(shot.stem)
        frame = f'<iframe src="{html.escape(mock)}" width="412" height="915"></iframe>' if mock else "<p>Component, no mockup page</p>"
        rel = "../../" + shot.relative_to(ROOT).as_posix()
        rows.append(f'<section><h2>{html.escape(shot.stem)}</h2><div><img src="{html.escape(rel)}" width="412">{frame}</div></section>')
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        "<!doctype html><meta charset='utf-8'><title>Stage 1 review</title>"
        "<style>body{font:14px sans-serif;margin:24px}div{display:flex;gap:24px;align-items:flex-start}"
        "img,iframe{border:1px solid #ccc}</style>" + "".join(rows)
    )
    print(f"{len(shots)} screenshots -> {OUT.relative_to(ROOT)}")


main()
```

Run: `python3 tools/review_page.py`
Expected: a count of screenshots and `build/review/index.html`.

- [ ] **Step 3: Write the README**

`app2/README.md`:

````markdown
# ShopNexus app2

The native Android app of ShopNexus, a second-hand marketplace for Vietnam. Stage 1 holds the project foundation and one working slice, Khám phá → Listing detail → Chat with an in-person deal, on fake data.

The screens follow the HTML mockups in `.superdesign/` (rules in `.superdesign/design-system.md`); the deal model is `mohinh.md`. The spec and the implementation plan live in the umbrella repo, under `specs/` and `plans/`.

## Requirements

- JDK 21
- Android SDK with platform 36 (`ANDROID_HOME` set, or `sdk.dir` in `local.properties`)
- An API 36 emulator or a phone with Android 12 or later, to run the app

The Gradle wrapper is committed; there is no system Gradle.

## Commands

| Command | What it does |
|---|---|
| `./gradlew :app:installDebug` | builds and installs the debug app |
| `./gradlew check verifyRoborazziDebug` | unit tests, Robolectric UI tests, the raw-colour check, and the screenshot comparison |
| `./gradlew recordRoborazziDebug` | rewrites the screenshots in `src/test/screenshots` after a deliberate UI change |
| `python3 tools/review_page.py` | puts every screenshot next to its mockup in `build/review/index.html` |
| `python3 core/designsystem/tools/gen_symbols.py` | regenerates `Symbols.kt` after a change to `core/designsystem/symbols.txt` |

## Modules

| Module | Holds |
|---|---|
| `:app` | the activity, one back stack per tab, theme settings, the debug panel |
| `:feature:discover` | Khám phá and Listing detail |
| `:feature:deal` | Chat and the deal console |
| `:feature:placeholder` | the screen that stands in for later stages |
| `:core:designsystem` | theme, Be Vietnam Pro, Material Symbols, shared components, money sentences |
| `:core:navigation` | route keys, the navigator, deep links |
| `:core:model` | the domain types; the API contract for the server |
| `:core:domain` | the deal rules and the console state machine |
| `:core:data` | repository interfaces, fixtures, fakes and the seller simulator |
| `:core:testing` | test clocks, dispatchers, the screenshot harness |

## Fake data

Every repository runs on `FakeWorld`, filled from `core/data/src/main/resources/fixtures/`. The simulator plays Tuấn Kiệt: it accepts an offer after 2.4 s, proposes a meeting, agrees to a new one after 1.6 s, and refunds an incident record after 2.2 s.

In debug builds a long press on Home's location pill or on a pushed screen's title opens the debug panel. It jumps the deal to any console state, speeds the seller up, turns on network failures, switches the theme, and resets the data.

Deep links: `adb shell am start -d shopnexus://listing/p-iphone13` and `adb shell am start -d shopnexus://deal/d-kiet`.
````

Run: `python3 ~/.claude/skills/humanizing-writing/ai-tells.py --stats README.md` and fix every hit by rewriting the sentence.

- [ ] **Step 4: Write the CI workflow**

`app2/.github/workflows/check.yml`:

```yaml
name: check

on:
  pull_request:
  push:
    branches: [main]

jobs:
  check:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "21"
      - uses: gradle/actions/setup-gradle@v4
      - name: Check
        run: ./gradlew check verifyRoborazziDebug --stacktrace
      - name: Upload reports
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: reports
          path: |
            **/build/reports/**
            **/build/outputs/roborazzi/**
```

The hosted runner carries an Android SDK with accepted licences; AGP downloads platform 36 on first use. Screenshots recorded on this machine may differ from the runner's by font hinting; `changeThreshold = 0.01` in the harness absorbs that, and a larger difference shows in the uploaded `roborazzi` diff images.

- [ ] **Step 5: Run every check**

Run: `./gradlew clean check verifyRoborazziDebug`
Expected: BUILD SUCCESSFUL. Count the tests in the report (`build/reports/tests` of each module): about 150.

- [ ] **Step 6: Check the acceptance criteria**

1. The slice walks end to end with no dead control. On the API 36 emulator, walk Khám phá → iPhone 13 Pro → offer → wait for the seller → Đồng ý hẹn → all six checks → Quét mã → five stars → Máy có vấn đề? (pick any photo in the Photo Picker) → Gửi ghi nhận → Đã nhận tiền hoàn. Tap every other control on the three screens once: each one acts, opens a sheet, or opens the placeholder naming its stage. Also try the deep links from the README and back from each screen, including the predictive back gesture.
2. Every screen state has a screenshot reviewed against the mockup. Open `build/review/index.html`; for each pair note any difference in a list, fix it, re-record, and repeat until the list is empty.
3. Every rule in the spec's deal rules table has unit tests: `:core:domain` tests cover `codAllowed`, `handoverDeadline`, `refusalCost`, `offerRange`, `tierFor`, `pointsFor`, `rightsFor`, `canPost`, `moneyNotes` and `DealConsole.reduce`.
4. The console state machine has ViewModel tests on virtual time: `ChatViewModelTest`.
5. Every slice screen lays out at font scale 1.3: the `textFitsAtFontScale130` tests of Home, Listing detail and Chat pass, and the `font130` screenshots show no overlap.

- [ ] **Step 7: Commit**

```bash
git add app README.md .github tools
git commit -m "test: walk the whole slice end to end; add the README and the CI workflow

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
