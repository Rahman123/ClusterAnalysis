/*
 * PAM (K-medoids) data assignment step - assign sample data points to the nearest medoids
 *
 * @author: Iskander Mukhamedgaliyev
 */
public with sharing class ClusterPAMDataAssignmentStep extends ClusterIterableBase {
    public ClusterPAMDataAssignmentStep() {

    }

    public ClusterPAMDataAssignmentStep(Integer batchSize) {
        super(batchSize);
    }

    public override void init(ClusterAlgorithmRunner runner) {
        ClusterIterableBase.log.debug('Starting PAM data assignment step');
        super.init(runner);
        ClusterKMeansJobState jobState = (ClusterKMeansJobState)runner.getJobState();
        jobState.clusterAssignmentMatrix = new List<List<Id>>();
        for (Integer i=0; i < jobState.centroids.size(); i++) {
            jobState.clusterAssignmentMatrix.add(new List<Id>());
            jobState.centroids[i].cost = 0;
        }
    }

    protected override Object[] getRecords() {
        return ((ClusterKMeansJobState)this.runner.getJobState()).dataPoints;
    }

    public override void processRecords(Database.BatchableContext bc, Object[] scope) {
        ClusterDataPoint[] dataPoints = (ClusterDataPoint[])scope;
        ClusterKMeansJobState jobState = (ClusterKMeansJobState)this.runner.getJobState();
        ClusterModelWrapper model = jobState.model;
        Integer scopeSize = scope.size();
        List<ClusterDataPoint> centroids = jobState.centroids;
        Integer centroidSize = centroids.size();
        //Initializing cluster assignment matrix
        List<List<Id>> clusterAssignmentMatrix = new List<List<Id>>();
        Double[] centroidCosts = new Double[centroidSize];
        for (Integer i=0; i < centroidSize; i++) {
            centroidCosts[i] = 0;
            clusterAssignmentMatrix.add(new List<Id>());
        }
        Object[] currentObject;
        Map<Id, Integer> reassignedRecords = new Map<Id, Integer>();
        for (Integer sindex = 0; sindex < scopeSize; sindex++){
            ClusterDataPoint currentRecord = dataPoints[sindex];
            currentObject = currentRecord.values;
            //ClusterDataHelper.normalizeObject(currentObject, jobState);
            //Calculating min distance to centroids
            Integer nearestCentroidIndex = 0;
            Boolean isCentroid = false;
            Double minDistance = this.runner.calculateDistance(currentObject, centroids[nearestCentroidIndex].values);
            for (Integer cindex = 1; cindex < centroidSize; cindex++) {
                isCentroid = centroids[cindex].recordId == currentRecord.recordId;
                if (isCentroid) {
                    currentRecord.clusterIndex = null;
                    break;
                }
                Double distance = this.runner.calculateDistance(currentObject, centroids[cindex].values);
                if (Math.abs(distance) < Math.abs(minDistance)) {
                    minDistance = distance;
                    nearestCentroidIndex = cindex;
                }
            }
            if (!isCentroid) {
                //Reassigning to another cluster if needed
                if (currentRecord.clusterIndex != nearestCentroidIndex) {
                    currentRecord.clusterIndex = nearestCentroidIndex;
                    reassignedRecords.put(currentRecord.recordId, nearestCentroidIndex);
                    jobState.hasAssignmentChanged = true;
                    ClusterIterableBase.log.debug('Reassigning ' + currentRecord + ' to cluster ' + nearestCentroidIndex);
                }
                clusterAssignmentMatrix[nearestCentroidIndex].add(currentRecord.recordId);
                centroidCosts[nearestCentroidIndex] += minDistance;
            }
        }        
        //Aggregating cost for each centroid/medoid
        //Since batches run serially in Apex we don't need to lock/synchronize jobState
        for (Integer i=0; i < centroidSize; i++) {
            jobState.clusterAssignmentMatrix[i].addAll(clusterAssignmentMatrix[i]);
            jobState.centroids[i].cost += centroidCosts[i];
        }
        //Populating new clusters to data points
        for (Integer i=0; i < jobState.dataPoints.size(); i++) {
            Integer newClusterIndex = reassignedRecords.get(jobState.dataPoints[i].recordId);
            if (newClusterIndex != null) {
                jobState.dataPoints[i].clusterIndex = newClusterIndex;
            }
        }
    }
}
