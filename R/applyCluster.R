#' @title Find required number of points to sample next.
#'
#' @description
#' Applies DBSCAN algorithm to find local optimum candidate parameter sets, or adds
#' noise to local optimums to obtain required number of sets to sample.
#'
#' @param e the entire parent environment is made available to this function
#' @importFrom dbscan dbscan
#' @importFrom data.table fintersect uniqueN
#' @return The next parameter sets to try
#' @keywords internal

applyCluster <- function(e = parent.frame()) {

  locOpt <- copy(e$LocalOptims[,-"gradCount"])

  # Return this if process cannot run properly.

  if (is.null(e$minClusterUtility)) { # If minClusterUtility is NULL, only select best optimum.

    clusterPoints <- data.table(locOpt[order(-get("gpUtility"))][1,])

  } else{ # Else select the best N optimums that fall above minClusterUtility

    # Define relative Utility to compare to minClusterUtility.
    locOpt[,"relUtility" := get("gpUtility")/max(get("gpUtility"))]

    # run DBSCAN to determine which random points converged to the same place. If there are multiple
    # local optimums of the acquisition function present in the Gaussian process, this filters out the duplicates.
    Clust <- dbscan(locOpt[,e$boundsDT$N,with=FALSE],eps = (length(locOpt)-2)*sqrt(2)/1e3, minPts = 1)
    locOpt[,"Cluster" := Clust$cluster]

    # Take the best parameter set from each cluster.
    clusterPoints <- copy(locOpt[locOpt[,.I[which.max(get("relUtility"))], by = get("Cluster")]$V1])

    # Filter out clusters that did not exceed our minclusterUtility threshold.
    clusterPoints <- head(clusterPoints[get("relUtility") >= e$minClusterUtility,][order(-get("relUtility"))],e$runNew)

    # Get rid of the helper columns.
    clusterPoints[,`:=` ("relUtility" = NULL,"Cluster" = NULL)]

  }

  clusterPoints <- unMMScale(clusterPoints, e$boundsDT)
  clusterPoints$acqOptimum <- TRUE
  clustN <- nrow(clusterPoints)

  # Mark clusters as duplicates if they have already been attempted. Note that
  # parameters must match exactly. Whether or not we should eliminate 'close'
  # parameters is experimental, and could cause problems as the parameter space
  # becomes more fully explored.
  clusterPoints$Duplicate <- checkDup(
    clusterPoints[,e$boundsDT$N,with=FALSE]
    , e$ScoreDT[,e$boundsDT$N,with=FALSE]
  )


  # The next two while statements each, respectively:

  # Add noise to the cluster points until each one is unique (not in ScoreDT already).
  # If this is happening, it means the parameters are likely all integers.

  # Add noise until we obtain the necessary bulkNew unique parameter sets. If bulkNew
  # is 4, and we only have 2 clusters, we still need to obtain 2 parameter sets by adding noise.

  # This is not expensive, so tries is large.
  tries <- 1
  while(any(clusterPoints$Duplicate) & tries <= 1000) {

    if (tries >= 1000) {
      return("\n\nNoise could not be added to find unique parameter set. Are all of your parameters integers? Try increasing noiseAdd if you want to run longer. Stopping process and returning results so far.")
    }

    # Only replace custers that are not duplicates.
    fromNoise <- applyNoise(clusterPoints[clusterPoints$Duplicate,], e$boundsDT)
    if(any(class(fromNoise) == "character")) return(fromNoise)
    clusterPoints[clusterPoints$Duplicate,] <- fromNoise
    clusterPoints[clusterPoints$Duplicate,]$acqOptimum <- FALSE

    clusterPoints$Duplicate <- checkDup(
      clusterPoints[,e$boundsDT$N,with=FALSE]
      , e$ScoreDT[,e$boundsDT$N,with=FALSE]
    )

    tries <- tries + 1

  }

  clusterPoints$Duplicate <- NULL

  # Gaussian process will fail if it is fed duplicate parameter-score pairs.
  # This adds noise until unique values are found. If no unique values are
  # found after 1000 tries, the process stops. Selecting pairs from remaining
  # unexplored values becomes intractable when searching in high dimensions,
  # so random draws are compared to pre-searched parameter sets.
  tries <- 1
  newSet <- clusterPoints
  drawPoints <- max(e$runNew - nrow(newSet),0)

  while(tries <= 1000 & drawPoints > 0) {

    if (tries >= 1000) {
      return("\n\nCould not procure required number of unique parameter sets to run next scoring funciton. Stopping process and returning results so far.")
    }

    # Pull clusters, one at a time (repeating if necessary), most promising first. We add noise to these.
    newP <- clusterPoints[rep(1:nrow(clusterPoints),length.out = drawPoints),e$boundsDT$N, with = FALSE]
    noisyP <- applyNoise(newP, e$boundsDT)
    if(any(class(noisyP) == "character")) return(noisyP)

    # Getting fancy. Check to see if noisyP parameters already exist in noisyP,newSet, or ScoreDT.
    noisyP$Duplicate <- checkDup(noisyP,rbind(newSet[,e$boundsDT$N,with=FALSE],e$ScoreDT[,e$boundsDT$N,with=FALSE]))

    # If we obtained any unique pairs, add them to the list and keep trying (if necessary).
    if (any(!noisyP$Duplicate)) {

      noisyP <- noisyP[(!noisyP$Duplicate),]
      noisyP$Duplicate <- NULL
      noisyP$gpUtility <- calcAcq(as.matrix(minMaxScale(noisyP,e$boundsDT)),e$GPs,e$GPe,e$acq,1,e$kappa,e$eps)
      noisyP$acqOptimum <- FALSE
      newSet <- rbind(newSet,noisyP)

    }

    drawPoints <- max(e$runNew - nrow(newSet),0)
    tries <- tries + 1

  }

  return(newSet)

}
