/*
 * K-Means algorithm runner
 *
 * @author: Iskander Mukhamedgaliyev
 */
 public with sharing class ClusterKMeansRunner extends ClusterAlgorithmRunner {
    ClusterKMeansJobState state;
    Boolean useEuclideanDistance;
    Integer centroidAssignmentStepIndex;
    Integer centroidUpdateStepIndex;
    public ClusterKMeansRunner() {

    }

    public override ClusterAlgorithmRunner.ModelValidationResult validateModel(ClusterModelWrapper model) {
        ModelValidationResult result = super.validateModel(model);
        for (Integer i=0; i<model.fields.size(); i++) {
            if (model.fields[i].distanceType == ClusterConstants.FIELDTYPE_TEXT || model.fields[i].distanceType == ClusterConstants.FIELDTYPE_CATEGORY) {
                result.isValid = false;
                result.messages.add('K-Means only supports numeric fields. Please change model algorithm to K-Medoids or change the field distance type. Field ' + model.fields[i].name);
            }
        }
        if ((model.numberOfClusters < 2) || (model.parameters != null && model.parameters.size() > 0 && Integer.valueOf(model.parameters.get('numberOfClusters')) < 2)) {
            result.isValid = false;
            result.messages.add('The number of result clusters cannot be less than 2');
        }
        return result;
    }

    public override void init(ClusterModelWrapper model) {
        this.state = new ClusterKMeansJobState();
        this.state.currentAlgorithmStep = 0;
        this.state.iterationsCount = 0;
        this.state.model = model;
        model.numberOfClusters = Integer.valueOf(model.parameters.get('numberOfClusters'));
        model.distanceFunction = String.valueOf(model.parameters.get('distanceFunction'));
        this.useEuclideanDistance = model.distanceFunction == ClusterConstants.DISTANCE_EUCLIDEAN;
        //Initializing steps
        ClusterPrepareDataStep step1 = new ClusterPrepareDataStep();
        this.steps.add(step1);
        ClusterInitCentroidsStep step2 = new ClusterInitCentroidsStep(false);
        this.steps.add(step2);
        ClusterCentroidDataAssignmentStep step3 = new ClusterCentroidDataAssignmentStep(true, false, false, false);
        this.steps.add(step3);
        this.centroidAssignmentStepIndex = this.steps.size() - 1;
        ClusterKMeansCentroidUpdateStep step4 = new ClusterKMeansCentroidUpdateStep();
        this.steps.add(step4);
        this.centroidUpdateStepIndex = this.steps.size() - 1;
        ClusterSilhouetteScoreStep step5 = new ClusterSilhouetteScoreStep(ClusterConstants.getKMedoidsSwapBatchSize());
        this.steps.add(step5);
        super.init(model);
    }

    public override ClusterJobState getJobState() {
        return this.state;
    }

    public override void setJobState(ClusterJobState state) {
        this.state = (ClusterKMeansJobState)state;
    }

    public override void start() {
        super.start();
    }

    public override Boolean prepareNextStep() {
        Boolean isLastStep = false;
        if (this.state.currentAlgorithmStep == this.centroidUpdateStepIndex) {
            ClusterIterableBase.log.debug('Centroid update completed. Assigning data points to clusters');
            this.state.currentAlgorithmStep = this.centroidAssignmentStepIndex; //Go to reassign data points to new centroids step
            this.state.hasAssignmentChanged = false;
            this.state.iterationsCount++;
            isLastStep = false;
        }
        else if (this.state.currentAlgorithmStep >= this.steps.size() - 1) {
            ClusterJobManager.saveJobState(state, ClusterConstants.JOBSTATUS_COMPLETED, '');
            isLastStep = true;
        }
        else {
            if (this.state.currentAlgorithmStep == this.centroidAssignmentStepIndex) {
                if (this.state.iterationsCount > ClusterConstants.getMaxSwapIterations()) { 
                    ClusterIterableBase.log.debug('Maximum number of iterations reached, finishing K-means cycle');
                    this.state.currentAlgorithmStep = this.centroidUpdateStepIndex + 1; //Go to next step after centroid update                
                }
                else {
                    if (!this.state.hasAssignmentChanged) { //If assignment to clusters not changed
                        ClusterIterableBase.log.debug('Cluster assignment has not changed. Finishing K-means cycle');
                        this.state.currentAlgorithmStep = this.centroidUpdateStepIndex + 1; //Go to next step after centroid update
                    }
                    else {
                        ClusterIterableBase.log.debug('Cluster assignment has changed. Repeating K-means cycle');
                        this.state.currentAlgorithmStep = this.state.currentAlgorithmStep + 1;
                    }
                }
            }
            else {
                this.state.currentAlgorithmStep = this.state.currentAlgorithmStep + 1;
            }
            isLastStep = this.state.currentAlgorithmStep >= this.steps.size();
        }
        return isLastStep;
    }

    public override Double calculateDistance(Object[] currentObject, Object[] centroid) {
        return this.useEuclideanDistance ? ClusterDataHelper.calculateEuclideanDistance(currentObject, centroid, this.state) :
            ClusterDataHelper.calculateManhattanDistance(currentObject, centroid, this.state);
    }

    public override ClusterAlgorithmParameter[] getParameters(ClusterModelWrapper model) {
        List<ClusterAlgorithmParameter> parameters = new List<ClusterAlgorithmParameter>();
        Object clusterNumber = model == null ? 4 : model.numberOfClusters;
        parameters.add(new ClusterAlgorithmParameter('numberOfClusters', 'Number of clusters', ClusterAlgorithmParameter.ParameterType.INTEGER_PARAMETER, clusterNumber, null));
        parameters.add(new ClusterAlgorithmParameter('distanceFunction', 'Distance Function', ClusterAlgorithmParameter.ParameterType.SELECT_PARAMETER, ClusterConstants.DISTANCE_EUCLIDEAN, 
            new String[]{ ClusterConstants.DISTANCE_MANHATTAN, ClusterConstants.DISTANCE_EUCLIDEAN }));
        return parameters;
    }
}
