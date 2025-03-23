terraform {
  cloud {
    organization = "mark_kharitonov"

    workspaces {
      name = "opp_site_checker"
    }
  }
}
