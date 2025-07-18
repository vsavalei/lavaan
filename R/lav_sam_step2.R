# SAM step 2: estimate structural part

lav_sam_step2 <- function(STEP1 = NULL, FIT = NULL,
                          sam.method = "local", struc.args = list()) {
  lavoptions <- FIT@Options
  lavpta <- FIT@pta
  nlevels <- lavpta$nlevels
  PT <- STEP1$PT

  # Gamma available?
  gamma.flag <- FALSE
  if (sam.method %in% c("local", "fsr", "cfsr") &&
      !is.null(STEP1$Gamma.eta[[1]])) {
    gamma.flag <- TRUE
  }

  LV.names <- unique(unlist(FIT@pta$vnames$lv.regular))

  # adjust options
  lavoptions.PA <- lavoptions
  if (lavoptions.PA$se == "naive") {
    lavoptions.PA$se <- "standard"
  } else if (gamma.flag) {
    lavoptions.PA$se <- "robust.sem"
    lavoptions.PA$test <- "satorra.bentler"
  } else {
    # twostep or none -> none
    lavoptions.PA$se <- "none"
  }
  # lavoptions.PA$fixed.x <- TRUE # may be false if indicator is predictor
  if (!lavoptions.PA$conditional.x) {
    lavoptions.PA$fixed.x <- FALSE # until we fix this...
  }
  lavoptions.PA$categorical <- FALSE
  lavoptions.PA$.categorical <- FALSE
  lavoptions.PA$rotation <- "none"
  lavoptions.PA <- modifyList(lavoptions.PA, struc.args)

  if (gamma.flag) {
    lavoptions.PA$check.vcov <- FALSE # always non-pd if interactions + fixed.x = FALSE
  }

  # override, no matter what
  lavoptions.PA$do.fit <- TRUE

  if (sam.method %in% c("local", "fsr", "cfsr")) {
    lavoptions.PA$missing <- "listwise"
    lavoptions.PA$sample.cov.rescale <- FALSE
    # lavoptions.PA$baseline <- FALSE
    # lavoptions.PA$h1 <- FALSE
    # lavoptions.PA$implied <- FALSE
    lavoptions.PA$loglik <- FALSE
  } else {
    lavoptions.PA$h1 <- FALSE
    # lavoptions.PA$implied <- FALSE
    lavoptions.PA$loglik <- FALSE
  }


  # construct PTS
  if (sam.method %in% c("local", "fsr", "cfsr")) {
    # extract structural part
    PTS <- lav_partable_subset_structural_model(PT,
      add.idx = TRUE,
      add.exo.cov = TRUE,
      fixed.x = lavoptions.PA$fixed.x,
      conditional.x = lavoptions.PA$conditional.x,
      free.fixed.var = TRUE,
      meanstructure = lavoptions.PA$meanstructure
    )

    # any 'extra' parameters: not (free) in PT, but free in PTS (user == 3)
    #  - fixed.x in PT, but fixed.x = FALSE is PTS
    #  - fixed-to-zero interceps in PT, but free in PTS
    #  - add.exo.cov: absent/fixed-to-zero in PT, but add/free in PTS
    extra.id <- which(PTS$user == 3L)

    # remove est/se/start columns
    PTS$est <- NULL
    PTS$se <- NULL
    PTS$start <- NULL

    if (nlevels > 1L) {
      PTS$level <- NULL
      PTS$group <- NULL
      PTS$group <- PTS$block
      NOBS <- FIT@Data@Lp[[1]]$nclusters
    } else {
      NOBS <- FIT@Data@nobs
    }

    # if meanstructure, 'free' user=0 intercepts?
    # if (lavoptions.PA$meanstructure) {
    #   extra.int.idx <- which(PTS$op == "~1" & PTS$user == 0L &
    #     PTS$free == 0L &
    #     PTS$exo == 0L) # needed?
    #   if (length(extra.int.idx) > 0L) {
    #     PTS$free[extra.int.idx] <- 1L
    #     PTS$ustart[extra.int.idx] <- as.numeric(NA)
    #     PTS$free[PTS$free > 0L] <-
    #       seq_len(length(PTS$free[PTS$free > 0L]))
    #     PTS$user[extra.int.idx] <- 3L
    #   }
    # } else {
    #   extra.int.idx <- integer(0L)
    # }
    # extra.id <- c(extra.id, extra.int.idx)

    reg.idx <- attr(PTS, "idx")
    attr(PTS, "idx") <- NULL
  } else {
    # global SAM

    # the measurement model parameters now become fixed ustart values
    PT$ustart[PT$free > 0] <- PT$est[PT$free > 0]

    reg.idx <- lav_partable_subset_structural_model(
      PT = PT,
      idx.only = TRUE
    )

    # remove 'exogenous' factor variances (if any) from reg.idx
    lv.names.x <- LV.names[LV.names %in% unlist(lavpta$vnames$eqs.x) &
      !LV.names %in% unlist(lavpta$vnames$eqs.y)]
    if ((lavoptions.PA$fixed.x || lavoptions.PA$std.lv) &&
        length(lv.names.x) > 0L) {
      var.idx <- which(PT$lhs %in% lv.names.x &
        PT$op == "~~" &
        PT$lhs == PT$rhs)
      rm.idx <- which(reg.idx %in% var.idx)
      if (length(rm.idx) > 0L) {
        reg.idx <- reg.idx[-rm.idx]
      }
    }

    # adapt parameter table for structural part
    PTS <- PT

    # remove constraints we don't need
    con.idx <- which(PTS$op %in% c("==", "<", ">", ":="))
    if (length(con.idx) > 0L) {
      needed.idx <- which(con.idx %in% reg.idx)
      if (length(needed.idx) > 0L) {
        con.idx <- con.idx[-needed.idx]
      }
      if (length(con.idx) > 0L) {
        PTS <- as.data.frame(PTS, stringsAsFactors = FALSE)
        PTS <- PTS[-con.idx, ]
      }
    }
    PTS$est <- NULL
    PTS$se <- NULL

    # 'fix' step 1 parameters
    PTS$free[!PTS$id %in% reg.idx & PTS$free > 0L] <- 0L

    # but free up residual variances if fixed (eg std.lv = TRUE) (new in 0.6-20)
    var.idx <- reg.idx[which(PT$free[reg.idx] == 0L &
                             PT$user[reg.idx] != 1L &
                             PT$op[reg.idx] == "~~")] # FIXME: more?
    PTS$free[var.idx] <- max(PTS$free) + seq_len(length(var.idx))

    # set 'ustart' values for free FIT.PA parameter to NA
    PTS$ustart[PTS$free > 0L] <- as.numeric(NA)

    PTS <- lav_partable_complete(PTS)

    extra.id <- extra.int.idx <- integer(0L)
  } # global

  # fit structural model
  if (lav_verbose()) {
    cat("Fitting the structural part ... \n")
  }
  if (sam.method %in% c("local", "fsr", "cfsr")) {
    if (gamma.flag) {
      NACOV <- STEP1$Gamma.eta
      ov.order <- "data"
    } else {
      NACOV <- NULL
      ov.order <- "model"
    }
    FIT.PA <- lavaan::lavaan(PTS,
      sample.cov  = STEP1$VETA,
      sample.mean = STEP1$EETA,
      sample.nobs = NOBS,
      NACOV       = NACOV,
      slotOptions = lavoptions.PA,
      verbose     = FALSE
    )
  } else {
    FIT.PA <- lavaan::lavaan(
      model = PTS,
      slotData = FIT@Data,
      slotSampleStats = FIT@SampleStats,
      slotOptions = lavoptions.PA,
      verbose = FALSE
    )
  }
  if (lav_verbose()) {
    cat("Fitting the structural part ... done.\n")
  }

  # which parameters from PTS do we wish to fill in:
  # - all 'free' parameters
  # - :=, <, > (if any)
  # - and NOT element with user=3 (add.exo.cov = TRUE, extra.int.idx)
  pts.idx <- which((PTS$free > 0L | (PTS$op %in% c(":=", "<", ">"))) &
    !PTS$user == 3L)

  # find corresponding rows in PT
  PTS2 <- as.data.frame(PTS, stringsAsFactors = FALSE)
  pt.idx <- lav_partable_map_id_p1_in_p2(PTS2[pts.idx, ], PT,
    exclude.nonpar = FALSE
  )
  # fill in
  PT$est[pt.idx] <- FIT.PA@ParTable$est[pts.idx]

  # create step2.free.idx
  p2.idx <- seq_len(length(PT$lhs)) %in% pt.idx & PT$free > 0 # no def!
  step2.free.idx <- STEP1$PT.free[p2.idx]

  # add 'step' column in PT
  PT$step <- rep(1L, length(PT$lhs))
  PT$step[seq_len(length(PT$lhs)) %in% reg.idx] <- 2L

  STEP2 <- list(
    FIT.PA = FIT.PA, PT = PT, reg.idx = reg.idx,
    step2.free.idx = step2.free.idx, extra.id = extra.id,
    pt.idx = pt.idx, pts.idx = pts.idx
  )

  STEP2
}
