# POC_CV

An iOS `UIKit` starter project structured around `Clean Architecture` and `MVVM-C`.

The current codebase provides a minimal but scalable foundation for:

- feature-based presentation modules
- coordinator-driven navigation
- centralized routing
- automatic flow cleanup when view controllers are removed

## Overview

The project is organized into three top-level layers:

- `Data`: external data sources and repository implementations
- `Domain`: business logic, entities, use cases, and repository contracts
- `Presentation`: UI, view models, coordinators, and routing

Inside `Presentation`, navigation follows the `MVVM-C` pattern:

- `ViewController` handles rendering and user interaction
- `ViewModel` prepares data and presentation state
- `Coordinator` owns screen flow and navigation decisions

## Project Structure

```text
POC_CV/
├── Data/
│   └── DataLayer.swift
├── Domain/
│   └── DomainLayer.swift
├── Presentation/
│   ├── App/
│   │   ├── AppCoordinator.swift
│   │   ├── AppDelegate.swift
│   │   └── SceneDelegate.swift
│   ├── Common/
│   │   ├── Coordinators/
│   │   │   ├── BaseCoordinator.swift
│   │   │   └── Coordinator.swift
│   │   └── Routing/
│   │       └── Router.swift
│   └── Home/
│       ├── HomeCoordinator.swift
│       ├── HomeViewController.swift
│       └── HomeViewModel.swift
└── Info.plist
```

## App Bootstrap Flow

The app starts entirely in code, without storyboards:

1. `SceneDelegate` creates the main `UIWindow`
2. `AppCoordinator` is initialized with that window
3. `AppCoordinator.start()` sets up the root navigation stack
4. `HomeCoordinator` creates the initial Home module
5. `Router` installs the module as the root screen

This keeps application startup thin and moves navigation ownership into coordinators.

## MVVM-C Base Components

### `Coordinator`

[`Coordinator.swift`](/Users/om/Projects/POC_CV/POC_CV/Presentation/Common/Coordinators/Coordinator.swift) defines the base contract for all coordinators:

- stores child coordinators
- exposes `start()` as the flow entry point

### `BaseCoordinator`

[`BaseCoordinator.swift`](/Users/om/Projects/POC_CV/POC_CV/Presentation/Common/Coordinators/BaseCoordinator.swift) provides shared lifecycle behavior:

- `addDependency(_:)` keeps child flows alive
- `removeDependency(_:)` releases child flows when they finish
- `finish()` triggers a completion hook for parent cleanup

This is the core mechanism used to avoid leaking child coordinators and to make flow termination explicit.

### `Router`

[`Router.swift`](/Users/om/Projects/POC_CV/POC_CV/Presentation/Common/Routing/Router.swift) wraps `UINavigationController` and centralizes navigation:

- `setRootModule(_:hideBar:)`
- `push(_:animated:onPop:)`
- `popModule(animated:)`
- `present(_:animated:completion:)`
- `dismissModule(animated:completion:)`

The router stores completion closures per view controller. When a screen is popped or dismissed, the corresponding completion is executed automatically. This allows coordinators to:

- release child flows
- clear references
- terminate navigation flows predictably

## Current Example Flow

The repository currently includes a minimal `Home` module:

- [`HomeCoordinator.swift`](/Users/om/Projects/POC_CV/POC_CV/Presentation/Home/HomeCoordinator.swift)
- [`HomeViewModel.swift`](/Users/om/Projects/POC_CV/POC_CV/Presentation/Home/HomeViewModel.swift)
- [`HomeViewController.swift`](/Users/om/Projects/POC_CV/POC_CV/Presentation/Home/HomeViewController.swift)

This module serves as the reference implementation for future screens.

## Recommended Module Pattern

For each new feature, follow this structure:

```text
Presentation/
└── FeatureName/
    ├── FeatureCoordinator.swift
    ├── FeatureViewController.swift
    └── FeatureViewModel.swift
```

As the project grows, each feature can be expanded into subfolders such as:

- `View`
- `ViewModel`
- `Coordinator`
- `Models`
- `Bindings`

## Extension Guidelines

Recommended next steps for scaling this base:

- add `Entities`, `UseCases`, and repository protocols under `Domain`
- add `Repositories`, `RemoteDataSources`, and `LocalDataSources` under `Data`
- introduce dependency injection through a `DependencyContainer` or factory layer
- create `BaseViewController` and `BaseViewModel` only if shared behavior becomes real and repeated
- keep navigation decisions inside coordinators, not inside view controllers

## Development Notes

- The app is storyboard-free and boots fully in code
- Navigation is coordinator-driven
- Flow cleanup is handled through router callbacks
- The current implementation is intentionally small to keep the base easy to evolve
